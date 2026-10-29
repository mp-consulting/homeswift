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
  const {
    $, el, tile, request, platform, explain, breadcrumb, api, act,
    updateDevice, putDevice, findDevice, setKey, poll, renderKeyed, canonicalMAC, isMAC, sameMAC,
  } = homeswift;
  const { t, tn } = HomeswiftI18n;

  // MARK: Your TVs

  const list = $("#tvs");
  let tvs = [];

  const sendKey = (tv, key) => (event) => act(event.currentTarget, () => request("key", { method: "POST", body: { mac: tv.mac, key } }));
  const keyButton = (tv, key, label, attrs = {}) => el("button", { text: label, disabled: !tv.reachable, onclick: sendKey(tv, key), ...attrs });
  // The mini remote's actions as the TV's own keys.
  const tvKeys = {
    up: "CursorUp", down: "CursorDown", left: "CursorLeft", right: "CursorRight", select: "Confirm", back: "Back", home: "Home",
    info: "Info", playPause: "PlayPause", mute: "Mute", volumeUp: "VolumeUp", volumeDown: "VolumeDown",
  };

  function tvCard(tv) {
    const state = tv.on ? [t("On"), "on"] : tv.reachable ? [t("Standby"), "standby"] : [t("Not responding"), "away"];
    const updates = tv.longPoll === "confirmed" ? t("Updates pushed by the TV") : tv.longPoll === "waiting" ? t("Waiting for the TV's push") : t("Polling for changes");
    const body = tv.on
      ? el("div", { class: "facts" },
        el("div", { class: "fact" }, el("span", { text: t("Input") }), el("b", { text: tv.currentInput ?? tv.currentApp ?? "—", title: tv.currentApp ?? "" })),
        el("div", { class: "fact" }, el("span", { text: "Ambilight" }), el("b", { text: tv.ambilight ? styleName(tv.ambilightStyle) : t("Off") })),
        el("div", { class: "fact" }, el("span", { text: t("Sound") }), el("b", { text: tv.muted ? t("Muted") : t("On") })))
      : el("div", { class: "off-note" },
        el("p", { text: tv.reachable ? t("In standby. Its input and Ambilight show once it is on.") : t("Off, or not on the network. Wake sends a Wake-on-LAN packet.") }),
        tv.reachable ? null : explain({
          error: `The TV ${tv.name} does not answer at ${tv.ip}.`,
          context: "The Homeswift plugin polls the Philips TV's JointSpace API over HTTPS on port 1926; after two polls without an answer the TV is shown as not responding.",
          device: { model: "Philips Android TV with Ambilight", certificatePinned: tv.pinned, updates: tv.longPoll },
        }));
    return el("div", { class: "card tv" },
      el("div", { class: "tv-head" },
        tile("accessory", "blue"),
        el("div", { class: "who" }, el("strong", { text: tv.name }), el("div", { class: "muted", text: `${tv.ip} · ${tv.mac}` })),
        el("span", { class: `pill status ${state[1]}`, text: state[0] })),
      body,
      HomeswiftRemote.build({
        actions: Object.keys(tvKeys), label: t("Remote for {name}", { name: tv.name }), disabled: !tv.reachable,
        send: (action) => request("key", { method: "POST", body: { mac: tv.mac, key: tvKeys[action] } }),
        extra: [
          tv.on
            ? keyButton(tv, "Standby", t("Turn off"))
            : el("button", { actionIcon: "power", class: "primary", text: t("Wake"), onclick: (event) => act(event.currentTarget, () => request(`wake?mac=${encodeURIComponent(tv.mac)}`, { method: "POST" })) }),
          keyButton(tv, "AmbilightOnOff", "Ambilight"),
        ],
      }),
      el("div", { class: "tv-foot muted" },
        el("span", { text: [tn("{n} input", "{n} inputs", tv.inputs), updates, tv.pinned ? t("Certificate pinned") : t("Certificate not pinned, pair again to pin it")].join(" · ") }),
        // The same menu as the Accessories page's cards, with what this page adds.
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: tv.name }), () => [
          { label: t("Inputs"), icon: "inputs", onSelect: () => openSources(tv) },
          { label: t("Edit"), icon: "edit", onSelect: () => openEditor(tv) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(`${platform}:${tv.mac}`)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my TV {name}: ", { name: tv.name })) } : null,
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => removeTV(tv).catch((e) => HomeswiftCommon.showAlert(e.message)) },
        ])));
  }

  /// `FOLLOW_VIDEO` as "Follow video"; nil as "On".
  const styleNames = { FOLLOW_VIDEO: t("Follow video"), FOLLOW_AUDIO: t("Follow audio"), FOLLOW_COLOR: t("Follow color"), "LOUNGE LIGHT": t("Lounge light") };
  const styleName = (style) => style ? styleNames[style] ?? style.replaceAll("_", " ").toLowerCase().replace(/^./, (c) => c.toUpperCase()) : t("On");

  // A card drawn again because its TV changed (an input, the sound) stays still: only a TV new to the page
  // arrives with the material's animation.
  const shown = new Set();
  function card(tv) {
    const node = tvCard(tv);
    if (shown.has(tv.mac)) node.classList.add("redrawn");
    shown.add(tv.mac);
    return node;
  }

  async function refresh() {
    try {
      ({ tvs } = await request("tvs"));
      if (tvs.length === 0) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No TV yet. Switch your TV on, then add it above.") })));
        }
        if (!pairingOpened) openPairing(false);
        return;
      }
      // Only the card of a TV that changed is drawn again: keep the keyboard on the remote it was on.
      const focused = document.activeElement?.closest?.(".tv")?.dataset.key;
      renderKeyed(list, tvs, (tv) => tv.mac, card);
      if (focused && !list.contains(document.activeElement)) list.querySelector(`.tv[data-key="${CSS.escape(focused)}"] .pad`)?.focus();
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: Inputs: the Homebridge plugin's sources editor. Shown inputs in the wheel's order, dragged to
  // reorder (the row follows the pointer, the others make room) or moved with Alt+↑/↓; hidden inputs in a
  // pool; names edited in place. Nothing is written until Save, since a save reloads the plugin.

  const sourcesCard = $("#sources");
  const kindLabels = { tv: "TV", home: t("Home"), hdmi: "HDMI", channel: t("Channel"), app: t("App"), custom: t("Custom") };
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let editing = null;   // { tv, sources: [{ id, name, kind, customName, visible }], saved: JSON }

  async function openSources(tv) {
    if (!(await closeEditor())) return;
    editing = { tv, sources: [], saved: "" };
    breadcrumb(t("Inputs of {name}", { name: tv.name }), closeSources);
    sourcesCard.classList.remove("hidden");
    sourcesCard.replaceChildren(el("p", { class: "muted", text: t("Loading the inputs of {name}…", { name: tv.name }) }));
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
  async function closeSources() {
    if (editing && isDirty() && !await HomeswiftCommon.confirmDialog(t("Discard the changes to the inputs?"))) return false;
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
    const shownList = el("ol", { class: "sources", "aria-label": t("Shown inputs, in order") }, shown.map((source) => sourceRow(source, true)));
    const hiddenList = el("ul", { class: "sources pool", "aria-label": t("Hidden inputs") }, hidden.map((source) => sourceRow(source, false)));
    const dirty = isDirty();
    sourcesCard.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", { text: t("Inputs of {name}", { name: editing.tv.name }) }),
          el("p", { class: "muted", text: editing.note ?? t("The order of the input wheel in the Home app. Drag a row by its handle, or press Alt and an arrow key. Click a name to rename it.") })),
        el("div", { class: "head-actions" },
          el("button", { actionIcon: "restore", class: "link", text: t("Refresh from TV"), title: t("Read the TV's apps again"), onclick: (event) => act(event.currentTarget, refreshSources) }),
          el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closeSources }))),
      el("div", { class: "panel-columns" },
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status on", text: t("Shown · {n}", { n: shown.length }) }), el("span", { class: "muted", text: t("drag to reorder") })),
          shown.length ? shownList : el("p", { class: "muted empty-list", text: t("No input is shown.") })),
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status standby", text: t("Hidden · {n}", { n: hidden.length }) }), el("span", { class: "muted", text: t("+ shows an input") })),
          hidden.length ? hiddenList : el("p", { class: "muted empty-list", text: t("Every input is shown.") }))),
      el("div", { class: `save-bar ${dirty ? "dirty" : ""}` },
        el("span", { class: "muted", text: dirty ? t("Unsaved changes") : t("Saved. The Home app shows this order.") }),
        el("button", { actionIcon: "restore", class: "link", text: t("Reset to the TV's order"), onclick: (event) => act(event.currentTarget, resetSources) }),
        el("button", { actionIcon: "close", text: t("Discard"), disabled: !dirty, onclick: () => { editing.sources = JSON.parse(editing.saved); renderSources(); } }),
        el("button", { actionIcon: "check", class: "primary", text: t("Save"), disabled: !dirty, onclick: (event) => act(event.currentTarget, saveSources) })));
    if (shown.length) enableSorting(shownList);
  }

  function sourceRow(source, shown) {
    const name = el("input", {
      class: "source-name", value: source.customName || source.name, placeholder: source.name, maxLength: 64,
      "aria-label": t("Name of {name}", { name: source.name }), spellcheck: false,
    });
    name.addEventListener("change", () => {
      const typed = name.value.trim();
      source.customName = typed && typed !== source.name ? typed : "";
      name.value = source.customName || source.name;
      renderSources();
    });
    name.addEventListener("keydown", (event) => { if (event.key === "Enter") name.blur(); });
    const toggle = el("button", {
      class: "icon-button", text: shown ? "×" : "+", title: shown ? t("Hide") : t("Show"),
      "aria-label": shown ? t("Hide {name}", { name: source.customName || source.name }) : t("Show {name}", { name: source.customName || source.name }),
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
      source.customName ? el("span", { class: "original muted", text: source.name, title: t("The name the TV gives it") }) : null,
      toggle);
    if (shown) {
      row.setAttribute("aria-label", t("{name}. Press Alt and an arrow key to move it.", { name: source.customName || source.name }));
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
    const grip = el("span", { class: "handle", "aria-hidden": "true", title: t("Drag to reorder") });
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

  /// "Refresh from TV": the plugin reads the TV's apps now. Unsaved changes stay; new inputs join their column
  /// at the end, inputs the TV no longer has go.
  async function refreshSources() {
    const tv = editing.tv;
    const { sources } = await request("sources/refresh", { method: "POST", body: { mac: tv.mac } });
    if (!editing || editing.tv !== tv) return;
    const fresh = sources.map((source) => ({ ...source, customName: source.customName ?? "" }));
    const known = new Set(editing.sources.map((source) => source.id));
    const added = fresh.filter((source) => !known.has(source.id));
    if (isDirty()) {
      const present = new Set(fresh.map((source) => source.id));
      const kept = editing.sources.filter((source) => present.has(source.id));
      editing.sources = [...kept.filter((s) => s.visible), ...added.filter((s) => s.visible), ...kept.filter((s) => !s.visible), ...added.filter((s) => !s.visible)];
    } else {
      editing.sources = [...fresh.filter((source) => source.visible), ...fresh.filter((source) => !source.visible)];
      editing.saved = JSON.stringify(editing.sources);
    }
    editing.note = added.length
      ? tn("{n} new input from the TV: {names}.", "{n} new inputs from the TV: {names}.", added.length, { names: added.map((source) => source.name).join(", ") })
      : t("The TV has no new app.");
    renderSources();
  }

  async function resetSources() {
    if (!await HomeswiftCommon.confirmDialog(t("Put the inputs of {name} back in the TV's order, all shown, with their own names?", { name: editing.tv.name }))) return;
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
  const deviceSchema = () => (schemaPromise ??= api(`/api/plugins/${encodeURIComponent(platform)}/schema`)
    .then((schema) => schema.schema.properties.devices.items.properties));
  const choices = (property) => (property.oneOf ? property.oneOf.map((o) => [o.enum[0], o.title]) : (property.enum || []).map((v) => [v, v]));
  let editorState = null;   // { tv, draft, saved, section }

  const fieldRow = (label, control, help) => el("label", { class: "field" }, el("span", { class: "field-title", text: label }), control, help ? el("span", { class: "help", text: help }) : null);

  /// "Get MAC" next to a MAC address field: the plugin asks the TV when it is configured, else reads this
  /// machine's ARP table, which has the TV once it answered on the network.
  function macButton(ipOf, input, report) {
    return el("button", { actionIcon: "search", type: "button", text: t("Get MAC"), onclick: (event) => {
      event.preventDefault();
      act(event.currentTarget, async () => {
        const ip = (ipOf() ?? "").trim();
        if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) throw new Error(t("Enter the TV's IPv4 address first."));
        const { mac } = await request(`mac?ip=${encodeURIComponent(ip)}`);
        input.value = mac;
        input.dispatchEvent(new Event("input"));
      }, report);
    } });
  }
  function toggleRow(label, checked, onChange, help) {
    const input = el("input", { type: "checkbox", checked });
    input.addEventListener("change", () => onChange(input.checked));
    return el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: label }), help ? el("span", { class: "help", text: help }) : null));
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
      toggleRow(t("Source switches"), draft.sourceSwitches === true, (on) => { setKey(draft, "sourceSwitches", on, false); changed(); }, schema.sourceSwitches.description),
      toggleRow(t("Ambilight + Hue switch"), draft.ambilightHueSwitch === true, (on) => { setKey(draft, "ambilightHueSwitch", on, false); changed(); }, schema.ambilightHueSwitch.description),
      el("p", { class: "help sensors-help", text: schema.stateSensors.description }),
      sensorToggle("power", t("Power sensor: motion while the TV is on")),
      sensorToggle("ambilight", t("Ambilight sensor: motion while Ambilight is on")),
      sensorToggle("mute", t("Mute sensor: motion while the sound is muted")),
    ];
  }

  async function openEditor(tv) {
    if (!(await closeSources()) || !(await closeEditor())) return;
    editorCard.classList.remove("hidden");
    breadcrumb(t("Edit {name}", { name: tv.name }), closeEditor);
    editorCard.replaceChildren(el("p", { class: "muted", text: t("Loading {name}…", { name: tv.name }) }));
    editorCard.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
    try {
      const [schema, device] = await Promise.all([deviceSchema(), findDevice(tv.mac)]);
      if (!device) throw new Error(t("This TV is not in the configuration."));
      editorState = { tv, schema, draft: structuredClone(device), saved: JSON.stringify(device), section: "general" };
      renderEditor();
    } catch (e) {
      editorCard.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  /// Closes the editor; false when the person keeps unsaved changes.
  async function closeEditor() {
    if (editorState && JSON.stringify(editorState.draft) !== editorState.saved && !await HomeswiftCommon.confirmDialog(t("Discard the changes to this TV?"))) return false;
    if (!editorCard.classList.contains("hidden")) breadcrumb(null);
    editorState = null;
    editorCard.classList.add("hidden");
    editorCard.replaceChildren();
    return true;
  }

  function renderEditor() {
    const { tv, schema, draft } = editorState;
    const message = el("span", { class: "muted" });
    const report = (text) => { message.className = "error"; message.textContent = text; };
    const save = el("button", { actionIcon: "check", class: "primary", text: t("Save"), onclick: (event) => act(event.currentTarget, saveEditor, report) });
    const discard = el("button", { actionIcon: "close", text: t("Discard"), onclick: () => { editorState.draft = JSON.parse(editorState.saved); renderEditor(); } });
    const changed = () => {
      const dirty = JSON.stringify(editorState.draft) !== editorState.saved;
      save.disabled = !dirty;
      discard.disabled = !dirty;
      message.className = dirty ? "dirty" : "muted";
      message.textContent = dirty ? t("Unsaved changes") : t("Saved");
    };
    const sections = [["general", t("General")], ["remote", t("Remote")], ["automations", t("Automations")], ["apps", t("Apps")], ["buttons", t("Buttons")]];
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
          fieldRow(t("Name in the Home app"), text("name", { maxLength: 64 })),
          fieldRow(t("Address"), text("ip", { inputmode: "decimal" }), t("The TV's IPv4 address. Give it a fixed address in your router.")),
          fieldRow(t("MAC address"), (() => {
            const input = text("mac");
            return el("div", { class: "with-button" }, input, macButton(() => draft.ip, input, report));
          })(), t("For Wake-on-LAN, which switches the TV on from deep standby.")),
          fieldRow(t("Ambilight style"), selectFor(schema.ambilightMode, draft.ambilightMode, (value) => { setKey(draft, "ambilightMode", value, schema.ambilightMode.default); changed(); }), schema.ambilightMode.description),
          fieldRow(t("Polling interval (ms)"), interval, schema.pollingInterval.description)),
        toggleRow(t("Switch Ambilight on whenever the TV comes on"), draft.ambilightOnStart === true, (on) => { setKey(draft, "ambilightOnStart", on, false); changed(); }),
        toggleRow("Wake-on-LAN", draft.wakeOnLanEnabled !== false, (on) => { setKey(draft, "wakeOnLanEnabled", on, true); changed(); }, schema.wakeOnLanEnabled.description),
        el("div", { class: "repair" },
          el("div", {}, el("strong", { text: t("Pairing") }),
            el("p", { class: "help", text: tv.pinned ? t("Paired, with the TV's certificate pinned. Pair again after a reset of the TV, when it refuses Homeswift.") : t("Paired without a pinned certificate. Pair again to pin it.") })),
          el("button", { actionIcon: "restore", text: t("Pair again"), onclick: async () => { if (await closeEditor()) repair(tv); } })));
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
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", { text: t("Edit {name}", { name: tv.name }) }), el("p", { class: "muted", text: t("Saving applies at once: the TV keeps its place in the Home app.") })),
        el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closeEditor })),
      tabs, el("div", { class: "editor-body" }, body),
      el("div", { class: "save-bar" }, message, discard, save));
    changed();
  }

  /// Apps the TV does not list: added by hand, or from what is in the TV's foreground ("Detect from TV").
  function appsSection(schema, draft, changed) {
    const apps = draft.customApps || [];
    const appName = el("input", { type: "text", placeholder: "EON", maxLength: 64 });
    const packageName = el("input", { type: "text", placeholder: "com.ug.eon.android.tv", spellcheck: false });
    const className = el("input", { type: "text", placeholder: t("Found by the plugin when left empty"), spellcheck: false });
    const status = el("p", { class: "status-line muted" });
    const detect = el("button", { actionIcon: "search", text: t("Detect from TV"), onclick: (event) => act(event.currentTarget, async () => {
      status.className = "status-line muted";
      status.textContent = t("Asking the TV which app is open…");
      const { app } = await request(`current-app?mac=${encodeURIComponent(editorState.tv.mac)}`);
      packageName.value = app.packageName;
      className.value = app.className ?? "";
      if (!appName.value) appName.value = app.name ?? "";
      status.className = "status-line ok";
      status.textContent = t("Found {name}.", { name: app.packageName });
    }, (text) => { status.className = "status-line error"; status.replaceChildren(text); }) });
    const add = el("button", { actionIcon: "plus", class: "primary", text: t("Add app"), onclick: () => {
      if (!appName.value.trim() || !packageName.value.trim()) { status.className = "status-line error"; status.textContent = t("An app needs a name and a package name."); return; }
      const app = { name: appName.value.trim(), packageName: packageName.value.trim() };
      if (className.value.trim()) app.className = className.value.trim();
      draft.customApps = [...apps.filter((a) => a.packageName !== app.packageName), app];
      changed();
    } });
    return el("div", {},
      el("p", { class: "help", text: schema.customApps.description }),
      apps.length ? el("ul", { class: "entries" }, apps.map((app) => el("li", {},
        el("div", {}, el("strong", { text: app.name }), el("div", { class: "muted mono", text: [app.packageName, app.className].filter(Boolean).join(" / ") })),
        el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => { setKey(draft, "customApps", apps.filter((a) => a !== app).length ? apps.filter((a) => a !== app) : undefined); changed(); } }))))
        : el("p", { class: "muted empty-list", text: t("No custom app.") }),
      el("div", { class: "add-box" },
        el("strong", { text: t("Add an app") }),
        el("div", { class: "fields" }, fieldRow(t("Name"), appName), fieldRow(t("Package name"), packageName), fieldRow(t("Launch activity (optional)"), className)),
        el("div", { class: "actions" }, detect, add), status));
  }

  /// Momentary switches that send one remote key each.
  function buttonsSection(schema, draft, changed) {
    const buttons = draft.customButtons || [];
    const keys = schema.customButtons.items.properties.key.enum;
    const used = new Set(buttons.map((b) => b.key));
    const buttonName = el("input", { type: "text", placeholder: t("Power menu"), maxLength: 64 });
    const key = el("select", {}, keys.filter((k) => !used.has(k)).map((k) => el("option", { value: k, text: k.replace(/([a-z])([A-Z0-9])/g, "$1 $2") })));
    const status = el("p", { class: "status-line muted" });
    const add = el("button", { actionIcon: "plus", class: "primary", text: t("Add button"), disabled: key.options.length === 0, onclick: () => {
      if (!buttonName.value.trim()) { status.className = "status-line error"; status.textContent = t("A button needs a name."); return; }
      draft.customButtons = [...buttons, { name: buttonName.value.trim(), key: key.value }];
      changed();
    } });
    return el("div", {},
      el("p", { class: "help", text: schema.customButtons.description }),
      buttons.length ? el("ul", { class: "entries" }, buttons.map((button) => el("li", {},
        el("div", {}, el("strong", { text: button.name }), el("div", { class: "muted", text: t("Sends {key}", { key: button.key }) })),
        el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => { setKey(draft, "customButtons", buttons.filter((b) => b !== button).length ? buttons.filter((b) => b !== button) : undefined); changed(); } }))))
        : el("p", { class: "muted empty-list", text: t("No custom button.") }),
      el("div", { class: "add-box" },
        el("strong", { text: t("Add a button") }),
        el("div", { class: "fields" }, fieldRow(t("Name"), buttonName), fieldRow(t("Remote key"), key, t("Each key can be used by one button only."))),
        el("div", { class: "actions" }, add), status));
  }

  async function saveEditor() {
    const { tv, draft } = editorState;
    if (!draft.name) throw new Error(t("The TV needs a name."));
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(draft.ip ?? "")) throw new Error(t("The address must be an IPv4 address, like 192.168.1.20."));
    if (!isMAC(draft.mac)) throw new Error(t("The MAC address must look like AA:BB:CC:DD:EE:FF."));
    draft.mac = canonicalMAC(draft.mac);
    await updateDevice(tv.mac, () => draft);
    editorState.saved = JSON.stringify(draft);
    editorState.tv = { ...tv, name: draft.name, mac: draft.mac };
    renderEditor();
    setTimeout(refresh, 600);
  }

  async function removeTV(tv) {
    if (!await HomeswiftCommon.confirmDialog(t("Remove {name}? It leaves the Home app, with its scenes and automations.", { name: tv.name }))) return;
    if (editingTV(tv) && (!(await closeSources()) || !(await closeEditor()))) return;
    await updateDevice(tv.mac, () => null);
    await refresh();
  }
  const editingTV = (tv) => (editing && sameMAC(editing.tv.mac, tv.mac)) || (editorState && sameMAC(editorState.tv.mac, tv.mac));

  // MARK: Add a TV: find → PIN → confirm, one step at a time

  /// A sentence with a TV's name in bold: the translation's {name} becomes a <strong>.
  const withName = (text, name) => text.split("{name}").flatMap((part, i) => (i ? [el("strong", { text: name }), part] : [part]));

  // The wizard opens from "Add a TV" next to the TVs' heading, as Homebridge's "Pair a TV" does; on its own
  // while there is no TV yet, and for "Pair again".
  const pairing = $("#pairing");
  const addButton = $("#add-tv");
  let pairingOpened = false;
  function openPairing(scroll = true) {
    pairingOpened = true;
    pairing.classList.remove("hidden");
    addButton.setAttribute("aria-expanded", "true");
    if (scroll) pairing.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
  }
  function closePairing() {
    reset();
    pairing.classList.add("hidden");
    addButton.setAttribute("aria-expanded", "false");
    addButton.focus();
  }
  addButton.addEventListener("click", () => {
    if (pairing.classList.contains("hidden")) {
      openPairing();
      findButton.focus({ preventScroll: true });
    } else {
      closePairing();
    }
  });
  const stepNames = [t("Find"), t("PIN"), t("Confirm")];
  const steps = el("ol", { class: "steps" }, stepNames.map((label, i) => el("li", { "data-n": String(i + 1), text: label })));
  const status = el("p", { class: "status-line muted", role: "status" });
  const say = (message, kind = "muted") => { status.textContent = message; status.className = `status-line ${kind}`; };
  let target = null;   // { ip, name } of the TV being paired
  let device = null;   // what the TV handed out: ip, username, password, certFingerprint, mac
  let attempt = null;  // the TV last asked for a PIN, for the failure's Wake and Explain
  let repairing = null;   // the MAC of a configured TV paired again: its entry gets the new keys
  /// An error, with Explain when there is an Assistant, and Wake for the TV being paired (a TV in deep standby
  /// answers nothing until a Wake-on-LAN packet reaches it): a known TV by its MAC address, another by the MAC
  /// address this machine's ARP table has for its address.
  function fail(message) {
    say(message, "error");
    const known = attempt && tvs.find((tv) => tv.ip === attempt.ip);
    const sleeper = known ?? (attempt ? { name: attempt.name ?? attempt.ip, ip: attempt.ip } : null);
    status.append(
      sleeper ? el("button", { actionIcon: "power", class: "link", text: t("Wake {name}", { name: sleeper.name }), onclick: (event) => act(event.currentTarget, async () => {
        const address = sleeper.mac ?? (await request(`mac?ip=${encodeURIComponent(sleeper.ip)}`)).mac;
        await request("wake", { method: "POST", body: { mac: address, ip: sleeper.ip } });
        say(t("Sent. Give {name} a few seconds to start, then pair again.", { name: sleeper.name }), "ok");
      }, fail) }) : null,
      explain({ error: message, context: "Pairing a Philips Android TV from the Homeswift plugin page: POST pair/request on port 1926, the TV shows a PIN, then pair/grant with an HMAC of the PIN.", device: { model: "Philips Android TV with Ambilight" } }));
  }

  // Step 1: find the TV, or type its address.
  const found = el("div", { class: "found" });
  const address = el("input", { type: "text", placeholder: "192.168.1.20", inputmode: "decimal", autocomplete: "off", spellcheck: false, "aria-label": t("TV address") });
  const findButton = el("button", { actionIcon: "search", text: t("Find TVs"), onclick: (event) => act(event.currentTarget, discover, fail) });
  const find = el("div", { class: "step" },
    el("p", { class: "muted", text: t("Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds.") }),
    findButton, found,
    el("div", { class: "or", text: t("or enter its address") }),
    el("form", { class: "manual", onsubmit: (event) => { event.preventDefault(); act(event.submitter ?? manualPair, () => pair({ ip: address.value.trim() }), fail); } },
      address, el("button", { actionIcon: "key", type: "submit", text: t("Pair") })));
  const manualPair = find.querySelector(".manual button");

  // Step 2: the PIN the TV shows, a box per digit.
  const digits = [0, 1, 2, 3].map((i) => el("input", { type: "text", inputmode: "numeric", maxlength: 1, autocomplete: i === 0 ? "one-time-code" : "off", "aria-label": t("PIN digit {n}", { n: i + 1 }) }));
  const pinPrompt = el("p", {});
  const confirmPin = el("button", { actionIcon: "check", class: "primary", text: t("Confirm PIN"), onclick: (event) => act(event.currentTarget, grant, fail) });
  const pinStep = el("div", { class: "step" },
    pinPrompt, el("div", { class: "pin" }, digits),
    el("div", { class: "actions" }, confirmPin, el("button", { actionIcon: "close", class: "link", text: t("Cancel"), onclick: reset })));

  // Step 3: the details of the TV's entry.
  const tvName = el("input", { type: "text", maxlength: 64, autocomplete: "off", placeholder: t("Living Room TV") });
  const ipField = el("input", { type: "text", readOnly: true, tabIndex: -1 });
  const mac = el("input", { type: "text", placeholder: "AA:BB:CC:DD:EE:FF", autocomplete: "off", spellcheck: false });
  const macHelp = el("p", { class: "help", text: t("For Wake-on-LAN, which switches the TV on from deep standby.") });
  const modeField = el("div", { class: "wide" }, el("label", { text: t("Ambilight style when switched on from HomeKit") }));
  const onStart = el("input", { type: "checkbox", id: "ambilight-on-start" });
  const entryText = el("pre", { class: "json" });
  let options = {};   // what is chosen for the TV being added, from the schema: Ambilight style, remote, automations
  const moreOptions = el("details", { class: "group-box" }, el("summary", { text: t("Remote and automations") }));
  async function renderOptions() {
    options = {};
    const schema = await deviceSchema();
    modeField.replaceChildren(modeField.firstChild,
      selectFor(schema.ambilightMode, undefined, (value) => { setKey(options, "ambilightMode", value, schema.ambilightMode.default); showEntry(); }));
    moreOptions.replaceChildren(moreOptions.firstChild,
      el("div", { class: "fields" }, remoteFields(schema, options, showEntry)),
      automationFields(schema, options, showEntry));
  }
  const confirmStep = el("div", { class: "step" },
    el("div", { class: "form" },
      el("div", { class: "wide" }, el("label", { text: t("Name in the Home app") }), tvName),
      el("div", {}, el("label", { text: t("Address") }), ipField),
      el("div", {}, el("label", { text: t("MAC address") }), el("div", { class: "with-button" }, mac, macButton(() => ipField.value, mac, fail)), macHelp),
      modeField),
    el("div", { class: "check" }, el("label", { class: "switch" }, onStart, el("span", {})), el("label", { htmlFor: "ambilight-on-start", text: t("Switch Ambilight on whenever the TV comes on") })),
    moreOptions,
    el("div", { class: "actions" },
      el("button", { actionIcon: "plus", class: "primary", text: t("Add TV"), onclick: (event) => act(event.currentTarget, addToConfiguration, fail) }),
      el("button", { actionIcon: "close", class: "link", text: t("Cancel"), onclick: reset })),
    el("details", {}, el("summary", { text: t("The entry for config.json") }), entryText,
      el("button", { actionIcon: "copy", class: "link", text: t("Copy"), onclick: (event) => act(event.currentTarget, async () => { await HomeswiftCommon.copyText(entryText.textContent); say(t("Copied."), "ok"); }, fail) })));

  // After saving: the plugin reloads with the TV at once.
  const doneText = el("p", {});
  const done = el("div", { class: "step" },
    doneText,
    el("div", { class: "actions" }, el("button", { actionIcon: "check", class: "primary", text: t("Done"), onclick: closePairing }), el("button", { actionIcon: "plus", text: t("Add another TV"), onclick: reset })));

  const bodies = [find, pinStep, confirmStep, done];
  pairing.replaceChildren(
    el("div", { class: "panel-head" }, el("h2", { id: "add-title", text: t("Add a TV") }), el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closePairing })),
    steps, ...bodies, status);

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
    say(t("Looking for TVs…"));
    const answer = await request("discover");
    const known = new Set(tvs.map((tv) => tv.ip));
    const fresh = answer.tvs.filter((tv) => !known.has(tv.host));
    say(fresh.length ? "" : answer.tvs.length ? t("Every TV that answered is already added.") : t("No TV announced itself. Check it is on, or enter its address."));
    found.replaceChildren(...fresh.map((tv) => el("div", { class: "item" },
      el("div", {}, el("strong", { text: tv.name }), el("div", { class: "muted", text: tv.host })),
      el("button", { actionIcon: "key", class: "primary", text: t("Pair"), onclick: (event) => act(event.currentTarget, () => pair({ ip: tv.host, name: tv.name }), fail) }))));
  }

  /// Pairs a configured TV again (after a reset of the TV, or to pin its certificate): its entry keeps its
  /// settings and gets the new keys.
  async function repair(tv) {
    reset();
    repairing = tv.mac;
    steps.children[2].textContent = t("Done");
    openPairing();
    await act(manualPair, () => pair({ ip: tv.ip, name: tv.name }), fail);
  }

  async function pair(tv) {
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(tv.ip)) throw new Error(t("Enter the TV's IPv4 address, like 192.168.1.20."));
    attempt = tv;
    say(t("Asking the TV for a PIN…"));
    const answer = await request("pair", { method: "POST", body: { ip: tv.ip, name: "Homeswift" } });
    target = tv;
    pinPrompt.replaceChildren(...withName(t("Type the PIN {name} shows on screen."), tv.name ?? tv.ip));
    say(answer.certificateSeen ? "" : t("The TV answered over plain HTTP, so its certificate cannot be pinned."));
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
    if (pin().length !== 4) throw new Error(t("The PIN has four digits."));
    try {
      const answer = await request("pair/grant", { method: "POST", body: { ip: target.ip, pin: pin() } });
      device = answer.device;
      if (repairing) {
        await updateDevice(repairing, (entry) => {
          entry.username = device.username;
          entry.password = device.password;
          if (device.certFingerprint) entry.certFingerprint = device.certFingerprint; else delete entry.certFingerprint;
        });
        doneText.replaceChildren(...withName(answer.certificatePinned ? t("{name} is paired again, with its certificate pinned.") : t("{name} is paired again."), target.name ?? target.ip));
        show(3);
        say("");
        repairing = null;
        setTimeout(refresh, 600);
        return;
      }
      tvName.value = target.name ?? "";
      ipField.value = device.ip;
      mac.value = device.mac ?? "";
      onStart.checked = false;
      await renderOptions().catch(() => {});
      checkMAC();
      showEntry();
      show(2);
      say(answer.certificatePinned ? t("Paired, and the TV's certificate is pinned.") : t("Paired."), "ok");
      tvName.focus();
    } catch (e) {
      digits.forEach((digit) => { digit.value = ""; });
      digits[0].focus();
      throw e;
    }
  }

  function checkMAC() {
    const missing = !isMAC(mac.value);
    mac.classList.toggle("needs", missing);
    macHelp.textContent = missing && !mac.value.trim()
      ? t("The TV did not give it. Its network settings show it (Settings › Network › View network settings).")
      : t("For Wake-on-LAN, which switches the TV on from deep standby.");
  }

  function entry() {
    const result = { name: tvName.value.trim() || "Philips TV", ...device, ...options };
    if (mac.value.trim()) result.mac = canonicalMAC(mac.value); else delete result.mac;
    if (onStart.checked) result.ambilightOnStart = true;
    return result;
  }
  const showEntry = () => { if (device) entryText.replaceChildren(HomeswiftCommon.jsonHighlight(JSON.stringify(entry(), null, 2))); };
  [tvName, mac].forEach((field) => field.addEventListener("input", () => { if (field === mac) checkMAC(); showEntry(); }));
  onStart.addEventListener("change", showEntry);

  async function addToConfiguration() {
    const tv = entry();
    if (!isMAC(tv.mac)) { mac.focus(); throw new Error(t("A MAC address is needed to switch the TV on.")); }
    await putDevice(tv);
    doneText.replaceChildren(...withName(t("{name} is added. In the Home app, add it with the bridge's setup code: Add Accessory › More options, then the TV's name."), tv.name));
    say("");
    show(3);
    await refresh();
  }

  show(0);
  poll(refresh);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Ambilight TV page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Pair your Philips Android TVs and control them from here and from the Home app.": "Jumelez vos téléviseurs Philips Android TV et contrôlez-les d'ici et depuis l'app Maison.",
    "Your TVs": "Vos téléviseurs",
    "Add a TV": "Ajouter un téléviseur",
    "On": "Allumé",
    "Off": "Éteint",
    "Standby": "En veille",
    "Not responding": "Ne répond pas",
    "Updates pushed by the TV": "Mises à jour envoyées par le téléviseur",
    "Waiting for the TV's push": "En attente des envois du téléviseur",
    "Polling for changes": "Interrogation régulière",
    "Input": "Entrée",
    "Sound": "Son",
    "Muted": "Coupé",
    "In standby. Its input and Ambilight show once it is on.": "En veille. Son entrée et Ambilight s'affichent une fois allumé.",
    "Off, or not on the network. Wake sends a Wake-on-LAN packet.": "Éteint, ou absent du réseau. Réveiller envoie un paquet Wake-on-LAN.",
    "Remote for {name}": "Télécommande de {name}",
    "Turn off": "Éteindre",
    "Wake": "Réveiller",
    "{n} input": "{n} entrée",
    "{n} inputs": "{n} entrées",
    "Certificate pinned": "Certificat épinglé",
    "Certificate not pinned, pair again to pin it": "Certificat non épinglé, jumelez à nouveau pour l'épingler",
    "Actions for {name}": "Actions pour {name}",
    "Inputs": "Entrées",
    "Edit": "Modifier",
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my TV {name}: ": "À propos de mon téléviseur {name} : ",
    "Remove": "Supprimer",
    "Follow video": "Suivre la vidéo",
    "Follow audio": "Suivre l'audio",
    "Follow color": "Suivre la couleur",
    "Lounge light": "Lumière d'ambiance",
    "No TV yet. Switch your TV on, then add it above.": "Aucun téléviseur pour l'instant. Allumez votre téléviseur, puis ajoutez-le ci-dessus.",
    "Home": "Accueil",
    "Channel": "Chaîne",
    "App": "App",
    "Custom": "Perso",
    "Inputs of {name}": "Entrées de {name}",
    "Loading the inputs of {name}…": "Chargement des entrées de {name}…",
    "Discard the changes to the inputs?": "Annuler les modifications des entrées ?",
    "Shown inputs, in order": "Entrées affichées, dans l'ordre",
    "Hidden inputs": "Entrées masquées",
    "The order of the input wheel in the Home app. Drag a row by its handle, or press Alt and an arrow key. Click a name to rename it.": "L'ordre de la roue des entrées dans l'app Maison. Faites glisser une ligne par sa poignée, ou appuyez sur Alt et une flèche. Cliquez sur un nom pour le renommer.",
    "Refresh from TV": "Actualiser depuis le téléviseur",
    "Read the TV's apps again": "Relire les apps du téléviseur",
    "Close": "Fermer",
    "Shown · {n}": "Affichées · {n}",
    "drag to reorder": "glisser pour réordonner",
    "No input is shown.": "Aucune entrée n'est affichée.",
    "Hidden · {n}": "Masquées · {n}",
    "+ shows an input": "+ affiche une entrée",
    "Every input is shown.": "Toutes les entrées sont affichées.",
    "Unsaved changes": "Modifications non enregistrées",
    "Saved. The Home app shows this order.": "Enregistré. L'app Maison affiche cet ordre.",
    "Reset to the TV's order": "Rétablir l'ordre du téléviseur",
    "Discard": "Annuler les modifications",
    "Save": "Enregistrer",
    "Name of {name}": "Nom de {name}",
    "Hide": "Masquer",
    "Show": "Afficher",
    "Hide {name}": "Masquer {name}",
    "Show {name}": "Afficher {name}",
    "The name the TV gives it": "Le nom que lui donne le téléviseur",
    "{name}. Press Alt and an arrow key to move it.": "{name}. Appuyez sur Alt et une flèche pour la déplacer.",
    "Drag to reorder": "Glisser pour réordonner",
    "{n} new input from the TV: {names}.": "{n} nouvelle entrée du téléviseur : {names}.",
    "{n} new inputs from the TV: {names}.": "{n} nouvelles entrées du téléviseur : {names}.",
    "The TV has no new app.": "Le téléviseur n'a pas de nouvelle app.",
    "Put the inputs of {name} back in the TV's order, all shown, with their own names?": "Remettre les entrées de {name} dans l'ordre du téléviseur, toutes affichées, avec leurs propres noms ?",
    "Get MAC": "Obtenir l'adresse MAC",
    "Enter the TV's IPv4 address first.": "Saisissez d'abord l'adresse IPv4 du téléviseur.",
    "Source switches": "Interrupteurs de source",
    "Ambilight + Hue switch": "Interrupteur Ambilight + Hue",
    "Power sensor: motion while the TV is on": "Capteur d'alimentation : mouvement tant que le téléviseur est allumé",
    "Ambilight sensor: motion while Ambilight is on": "Capteur Ambilight : mouvement tant qu'Ambilight est allumé",
    "Mute sensor: motion while the sound is muted": "Capteur de sourdine : mouvement tant que le son est coupé",
    "Edit {name}": "Modifier {name}",
    "Loading {name}…": "Chargement de {name}…",
    "This TV is not in the configuration.": "Ce téléviseur n'est pas dans la configuration.",
    "Discard the changes to this TV?": "Annuler les modifications de ce téléviseur ?",
    "Saved": "Enregistré",
    "General": "Général",
    "Remote": "Télécommande",
    "Automations": "Automatisations",
    "Apps": "Apps",
    "Buttons": "Boutons",
    "Name in the Home app": "Nom dans l'app Maison",
    "Address": "Adresse",
    "The TV's IPv4 address. Give it a fixed address in your router.": "L'adresse IPv4 du téléviseur. Donnez-lui une adresse fixe dans votre routeur.",
    "MAC address": "Adresse MAC",
    "For Wake-on-LAN, which switches the TV on from deep standby.": "Pour le Wake-on-LAN, qui allume le téléviseur depuis la veille profonde.",
    "Ambilight style": "Style Ambilight",
    "Polling interval (ms)": "Intervalle d'interrogation (ms)",
    "Switch Ambilight on whenever the TV comes on": "Allumer Ambilight à chaque allumage du téléviseur",
    "Pairing": "Jumelage",
    "Paired, with the TV's certificate pinned. Pair again after a reset of the TV, when it refuses Homeswift.": "Jumelé, avec le certificat du téléviseur épinglé. Jumelez à nouveau après une réinitialisation du téléviseur, s'il refuse Homeswift.",
    "Paired without a pinned certificate. Pair again to pin it.": "Jumelé sans certificat épinglé. Jumelez à nouveau pour l'épingler.",
    "Pair again": "Jumeler à nouveau",
    "Saving applies at once: the TV keeps its place in the Home app.": "L'enregistrement s'applique aussitôt : le téléviseur garde sa place dans l'app Maison.",
    "Found by the plugin when left empty": "Trouvée par le plugin si vide",
    "Detect from TV": "Détecter sur le téléviseur",
    "Asking the TV which app is open…": "Interrogation du téléviseur sur l'app ouverte…",
    "Found {name}.": "{name} trouvée.",
    "Add app": "Ajouter l'app",
    "An app needs a name and a package name.": "Une app a besoin d'un nom et d'un nom de paquet.",
    "No custom app.": "Aucune app personnalisée.",
    "Add an app": "Ajouter une app",
    "Name": "Nom",
    "Package name": "Nom du paquet",
    "Launch activity (optional)": "Activité de lancement (facultatif)",
    "Power menu": "Menu d'alimentation",
    "Add button": "Ajouter le bouton",
    "A button needs a name.": "Un bouton a besoin d'un nom.",
    "Sends {key}": "Envoie {key}",
    "No custom button.": "Aucun bouton personnalisé.",
    "Add a button": "Ajouter un bouton",
    "Remote key": "Touche de la télécommande",
    "Each key can be used by one button only.": "Chaque touche ne sert qu'à un seul bouton.",
    "The TV needs a name.": "Le téléviseur a besoin d'un nom.",
    "The address must be an IPv4 address, like 192.168.1.20.": "L'adresse doit être une adresse IPv4, comme 192.168.1.20.",
    "The MAC address must look like AA:BB:CC:DD:EE:FF.": "L'adresse MAC doit ressembler à AA:BB:CC:DD:EE:FF.",
    "Remove {name}? It leaves the Home app, with its scenes and automations.": "Supprimer {name} ? Il quitte l'app Maison, avec ses scènes et automatisations.",
    "Find": "Rechercher",
    "PIN": "PIN",
    "Confirm": "Confirmer",
    "Done": "Terminé",
    "Wake {name}": "Réveiller {name}",
    "Sent. Give {name} a few seconds to start, then pair again.": "Envoyé. Laissez quelques secondes à {name} pour démarrer, puis jumelez à nouveau.",
    "TV address": "Adresse du téléviseur",
    "Find TVs": "Rechercher des téléviseurs",
    "Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds.": "Allumez le téléviseur : il doit être allumé et sur ce réseau. Homeswift le cherche pendant cinq secondes.",
    "or enter its address": "ou saisissez son adresse",
    "Pair": "Jumeler",
    "PIN digit {n}": "Chiffre {n} du PIN",
    "Confirm PIN": "Confirmer le PIN",
    "Cancel": "Annuler",
    "Living Room TV": "Téléviseur du salon",
    "Ambilight style when switched on from HomeKit": "Style Ambilight à l'allumage depuis HomeKit",
    "Remote and automations": "Télécommande et automatisations",
    "Add TV": "Ajouter le téléviseur",
    "The entry for config.json": "L'entrée pour config.json",
    "Copy": "Copier",
    "Copied.": "Copié.",
    "Add another TV": "Ajouter un autre téléviseur",
    "Looking for TVs…": "Recherche des téléviseurs…",
    "Every TV that answered is already added.": "Tous les téléviseurs qui ont répondu sont déjà ajoutés.",
    "No TV announced itself. Check it is on, or enter its address.": "Aucun téléviseur ne s'est annoncé. Vérifiez qu'il est allumé, ou saisissez son adresse.",
    "Enter the TV's IPv4 address, like 192.168.1.20.": "Saisissez l'adresse IPv4 du téléviseur, comme 192.168.1.20.",
    "Asking the TV for a PIN…": "Demande d'un PIN au téléviseur…",
    "Type the PIN {name} shows on screen.": "Saisissez le PIN affiché à l'écran par {name}.",
    "The TV answered over plain HTTP, so its certificate cannot be pinned.": "Le téléviseur a répondu en HTTP simple : son certificat ne peut pas être épinglé.",
    "The PIN has four digits.": "Le PIN a quatre chiffres.",
    "{name} is paired again, with its certificate pinned.": "{name} est de nouveau jumelé, avec son certificat épinglé.",
    "{name} is paired again.": "{name} est de nouveau jumelé.",
    "Paired, and the TV's certificate is pinned.": "Jumelé, et le certificat du téléviseur est épinglé.",
    "Paired.": "Jumelé.",
    "The TV did not give it. Its network settings show it (Settings › Network › View network settings).": "Le téléviseur ne l'a pas donnée. Ses réglages réseau l'indiquent (Réglages › Réseau › Afficher les paramètres réseau).",
    "A MAC address is needed to switch the TV on.": "Une adresse MAC est nécessaire pour allumer le téléviseur.",
    "{name} is added. In the Home app, add it with the bridge's setup code: Add Accessory › More options, then the TV's name.": "{name} est ajouté. Dans l'app Maison, ajoutez-le avec le code de configuration du pont : Ajouter un accessoire › Plus d'options, puis le nom du téléviseur.",
    "no TV with that MAC": "aucun téléviseur avec cette adresse MAC",
    "The inputs are listed in the configuration (inputs), so the TV's apps are not read.": "Les entrées sont listées dans la configuration (inputs) : les apps du téléviseur ne sont donc pas lues.",
    "{0} is off. Switch it on, wait for its Home screen, then refresh.": "{0} est éteint. Allumez-le, attendez son écran d'accueil, puis actualisez.",
    "{0} did not list its apps. A TV that just woke is slow to: try again once its Home screen shows.": "{0} n'a pas listé ses apps. Un téléviseur qui vient de se réveiller est lent à le faire : réessayez une fois son écran d'accueil affiché.",
    "an IPv4 address is required": "une adresse IPv4 est requise",
    "No MAC address found for that IP. Make sure the TV is on.": "Aucune adresse MAC trouvée pour cette IP. Vérifiez que le téléviseur est allumé.",
    "{0}. Is the TV on?": "{0}. Le téléviseur est-il allumé ?",
    "No app is in the foreground. Open the app on the TV, then try again.": "Aucune app n'est au premier plan. Ouvrez l'app sur le téléviseur, puis réessayez.",
    "A valid MAC address is required": "Une adresse MAC valide est requise",
    "unknown key": "touche inconnue",
    "the TV did not take the key": "le téléviseur n'a pas accepté la touche",
    "Cannot reach the TV at {0}: is it on, and on this network? ({1})": "Impossible de joindre le téléviseur à {0} : est-il allumé et sur ce réseau ? ({1})",
    "no pairing in progress for that address; start again": "aucun jumelage en cours pour cette adresse ; recommencez",
    "the pairing expired; start again": "le jumelage a expiré ; recommencez",
    "a 4-digit PIN is required": "un PIN à 4 chiffres est requis",
    "the TV did not answer: {0}": "le téléviseur n'a pas répondu : {0}",
    "the TV refuses connections on port {0}": "le téléviseur refuse les connexions sur le port {0}",
    "the TV answered HTTP {0}": "le téléviseur a répondu HTTP {0}",
    "the TV refused the credentials: pair it again": "le téléviseur a refusé les identifiants : jumelez-le à nouveau",
    "unexpected answer from the TV: {0}": "réponse inattendue du téléviseur : {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "le certificat du téléviseur ({0}) n'est pas celui épinglé ({1})",
    "Invalid PIN code. Please check the PIN on your TV screen and try again.": "Code PIN incorrect. Vérifiez le PIN sur l'écran du téléviseur et réessayez.",
    "Access denied. The TV rejected the pairing request.": "Accès refusé. Le téléviseur a rejeté la demande de jumelage.",
    "Pairing endpoint not found. Your TV may not support this pairing method.": "Point d'accès de jumelage introuvable. Votre téléviseur ne prend peut-être pas en charge cette méthode.",
    "Request timeout. The TV took too long to respond.": "Délai dépassé. Le téléviseur a mis trop de temps à répondre.",
    "TV internal error. Please try again.": "Erreur interne du téléviseur. Réessayez.",
    "TV is temporarily unavailable. Please try again later.": "Le téléviseur est momentanément indisponible. Réessayez plus tard."
  },
  "es": {
    "Pair your Philips Android TVs and control them from here and from the Home app.": "Empareja tus televisores Philips Android TV y contrólalos desde aquí y desde la app Casa.",
    "Your TVs": "Tus televisores",
    "Add a TV": "Añadir un televisor",
    "On": "Encendido",
    "Off": "Apagado",
    "Standby": "En reposo",
    "Not responding": "No responde",
    "Updates pushed by the TV": "Cambios enviados por el televisor",
    "Waiting for the TV's push": "Esperando los envíos del televisor",
    "Polling for changes": "Consulta periódica de cambios",
    "Input": "Entrada",
    "Sound": "Sonido",
    "Muted": "Silenciado",
    "In standby. Its input and Ambilight show once it is on.": "En reposo. Su entrada y Ambilight se muestran cuando está encendido.",
    "Off, or not on the network. Wake sends a Wake-on-LAN packet.": "Apagado o fuera de la red. Despertar envía un paquete Wake-on-LAN.",
    "Remote for {name}": "Mando de {name}",
    "Turn off": "Apagar",
    "Wake": "Despertar",
    "{n} input": "{n} entrada",
    "{n} inputs": "{n} entradas",
    "Certificate pinned": "Certificado fijado",
    "Certificate not pinned, pair again to pin it": "Certificado sin fijar, vuelve a emparejar para fijarlo",
    "Actions for {name}": "Acciones de {name}",
    "Inputs": "Entradas",
    "Edit": "Editar",
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my TV {name}: ": "Sobre mi televisor {name}: ",
    "Remove": "Eliminar",
    "Follow video": "Seguir el vídeo",
    "Follow audio": "Seguir el audio",
    "Follow color": "Seguir el color",
    "Lounge light": "Luz ambiental",
    "No TV yet. Switch your TV on, then add it above.": "Aún no hay ningún televisor. Enciende tu televisor y añádelo arriba.",
    "Home": "Inicio",
    "Channel": "Canal",
    "App": "App",
    "Custom": "Propia",
    "Inputs of {name}": "Entradas de {name}",
    "Loading the inputs of {name}…": "Cargando las entradas de {name}…",
    "Discard the changes to the inputs?": "¿Descartar los cambios de las entradas?",
    "Shown inputs, in order": "Entradas visibles, en orden",
    "Hidden inputs": "Entradas ocultas",
    "The order of the input wheel in the Home app. Drag a row by its handle, or press Alt and an arrow key. Click a name to rename it.": "El orden de la rueda de entradas en la app Casa. Arrastra una fila por su asa o pulsa Alt y una flecha. Haz clic en un nombre para cambiarlo.",
    "Refresh from TV": "Actualizar desde el televisor",
    "Read the TV's apps again": "Volver a leer las apps del televisor",
    "Close": "Cerrar",
    "Shown · {n}": "Visibles · {n}",
    "drag to reorder": "arrastra para reordenar",
    "No input is shown.": "No hay ninguna entrada visible.",
    "Hidden · {n}": "Ocultas · {n}",
    "+ shows an input": "+ muestra una entrada",
    "Every input is shown.": "Todas las entradas están visibles.",
    "Unsaved changes": "Cambios sin guardar",
    "Saved. The Home app shows this order.": "Guardado. La app Casa muestra este orden.",
    "Reset to the TV's order": "Restablecer el orden del televisor",
    "Discard": "Descartar",
    "Save": "Guardar",
    "Name of {name}": "Nombre de {name}",
    "Hide": "Ocultar",
    "Show": "Mostrar",
    "Hide {name}": "Ocultar {name}",
    "Show {name}": "Mostrar {name}",
    "The name the TV gives it": "El nombre que le da el televisor",
    "{name}. Press Alt and an arrow key to move it.": "{name}. Pulsa Alt y una flecha para moverla.",
    "Drag to reorder": "Arrastra para reordenar",
    "{n} new input from the TV: {names}.": "{n} entrada nueva del televisor: {names}.",
    "{n} new inputs from the TV: {names}.": "{n} entradas nuevas del televisor: {names}.",
    "The TV has no new app.": "El televisor no tiene apps nuevas.",
    "Put the inputs of {name} back in the TV's order, all shown, with their own names?": "¿Volver a poner las entradas de {name} en el orden del televisor, todas visibles y con sus propios nombres?",
    "Get MAC": "Obtener MAC",
    "Enter the TV's IPv4 address first.": "Introduce primero la dirección IPv4 del televisor.",
    "Source switches": "Interruptores de fuente",
    "Ambilight + Hue switch": "Interruptor Ambilight + Hue",
    "Power sensor: motion while the TV is on": "Sensor de encendido: movimiento mientras el televisor está encendido",
    "Ambilight sensor: motion while Ambilight is on": "Sensor de Ambilight: movimiento mientras Ambilight está encendido",
    "Mute sensor: motion while the sound is muted": "Sensor de silencio: movimiento mientras el sonido está silenciado",
    "Edit {name}": "Editar {name}",
    "Loading {name}…": "Cargando {name}…",
    "This TV is not in the configuration.": "Este televisor no está en la configuración.",
    "Discard the changes to this TV?": "¿Descartar los cambios de este televisor?",
    "Saved": "Guardado",
    "General": "General",
    "Remote": "Mando",
    "Automations": "Automatizaciones",
    "Apps": "Apps",
    "Buttons": "Botones",
    "Name in the Home app": "Nombre en la app Casa",
    "Address": "Dirección",
    "The TV's IPv4 address. Give it a fixed address in your router.": "La dirección IPv4 del televisor. Dale una dirección fija en tu router.",
    "MAC address": "Dirección MAC",
    "For Wake-on-LAN, which switches the TV on from deep standby.": "Para Wake-on-LAN, que enciende el televisor desde el reposo profundo.",
    "Ambilight style": "Estilo de Ambilight",
    "Polling interval (ms)": "Intervalo de consulta (ms)",
    "Switch Ambilight on whenever the TV comes on": "Encender Ambilight cada vez que se encienda el televisor",
    "Pairing": "Emparejamiento",
    "Paired, with the TV's certificate pinned. Pair again after a reset of the TV, when it refuses Homeswift.": "Emparejado, con el certificado del televisor fijado. Vuelve a emparejar tras restablecer el televisor, si rechaza Homeswift.",
    "Paired without a pinned certificate. Pair again to pin it.": "Emparejado sin certificado fijado. Vuelve a emparejar para fijarlo.",
    "Pair again": "Volver a emparejar",
    "Saving applies at once: the TV keeps its place in the Home app.": "Al guardar se aplica al momento: el televisor conserva su lugar en la app Casa.",
    "Found by the plugin when left empty": "La busca el plugin si se deja vacío",
    "Detect from TV": "Detectar en el televisor",
    "Asking the TV which app is open…": "Preguntando al televisor qué app está abierta…",
    "Found {name}.": "Encontrada: {name}.",
    "Add app": "Añadir app",
    "An app needs a name and a package name.": "Una app necesita un nombre y un nombre de paquete.",
    "No custom app.": "No hay apps personalizadas.",
    "Add an app": "Añadir una app",
    "Name": "Nombre",
    "Package name": "Nombre del paquete",
    "Launch activity (optional)": "Actividad de inicio (opcional)",
    "Power menu": "Menú de encendido",
    "Add button": "Añadir botón",
    "A button needs a name.": "Un botón necesita un nombre.",
    "Sends {key}": "Envía {key}",
    "No custom button.": "No hay botones personalizados.",
    "Add a button": "Añadir un botón",
    "Remote key": "Tecla del mando",
    "Each key can be used by one button only.": "Cada tecla solo puede usarla un botón.",
    "The TV needs a name.": "El televisor necesita un nombre.",
    "The address must be an IPv4 address, like 192.168.1.20.": "La dirección debe ser IPv4, como 192.168.1.20.",
    "The MAC address must look like AA:BB:CC:DD:EE:FF.": "La dirección MAC debe tener la forma AA:BB:CC:DD:EE:FF.",
    "Remove {name}? It leaves the Home app, with its scenes and automations.": "¿Eliminar {name}? Saldrá de la app Casa, con sus escenas y automatizaciones.",
    "Find": "Buscar",
    "PIN": "PIN",
    "Confirm": "Confirmar",
    "Done": "Listo",
    "Wake {name}": "Despertar {name}",
    "Sent. Give {name} a few seconds to start, then pair again.": "Enviado. Dale a {name} unos segundos para arrancar y vuelve a emparejar.",
    "TV address": "Dirección del televisor",
    "Find TVs": "Buscar televisores",
    "Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds.": "Enciende el televisor: debe estar encendido y en esta red. Homeswift lo busca durante cinco segundos.",
    "or enter its address": "o introduce su dirección",
    "Pair": "Emparejar",
    "PIN digit {n}": "Dígito {n} del PIN",
    "Confirm PIN": "Confirmar PIN",
    "Cancel": "Cancelar",
    "Living Room TV": "Televisor del salón",
    "Ambilight style when switched on from HomeKit": "Estilo de Ambilight al encenderlo desde HomeKit",
    "Remote and automations": "Mando y automatizaciones",
    "Add TV": "Añadir televisor",
    "The entry for config.json": "La entrada para config.json",
    "Copy": "Copiar",
    "Copied.": "Copiado.",
    "Add another TV": "Añadir otro televisor",
    "Looking for TVs…": "Buscando televisores…",
    "Every TV that answered is already added.": "Todos los televisores que han respondido ya están añadidos.",
    "No TV announced itself. Check it is on, or enter its address.": "Ningún televisor se ha anunciado. Comprueba que está encendido o introduce su dirección.",
    "Enter the TV's IPv4 address, like 192.168.1.20.": "Introduce la dirección IPv4 del televisor, como 192.168.1.20.",
    "Asking the TV for a PIN…": "Pidiendo un PIN al televisor…",
    "Type the PIN {name} shows on screen.": "Escribe el PIN que {name} muestra en pantalla.",
    "The TV answered over plain HTTP, so its certificate cannot be pinned.": "El televisor ha respondido por HTTP sin cifrar, así que su certificado no se puede fijar.",
    "The PIN has four digits.": "El PIN tiene cuatro dígitos.",
    "{name} is paired again, with its certificate pinned.": "{name} se ha vuelto a emparejar, con su certificado fijado.",
    "{name} is paired again.": "{name} se ha vuelto a emparejar.",
    "Paired, and the TV's certificate is pinned.": "Emparejado, y el certificado del televisor está fijado.",
    "Paired.": "Emparejado.",
    "The TV did not give it. Its network settings show it (Settings › Network › View network settings).": "El televisor no la ha dado. Sus ajustes de red la muestran (Ajustes › Red › Ver ajustes de red).",
    "A MAC address is needed to switch the TV on.": "Hace falta una dirección MAC para encender el televisor.",
    "{name} is added. In the Home app, add it with the bridge's setup code: Add Accessory › More options, then the TV's name.": "{name} se ha añadido. En la app Casa, añádelo con el código de configuración del puente: Añadir accesorio › Más opciones y luego el nombre del televisor.",
    "no TV with that MAC": "no hay ningún televisor con esa MAC",
    "The inputs are listed in the configuration (inputs), so the TV's apps are not read.": "Las entradas están en la configuración (inputs), así que no se leen las apps del televisor.",
    "{0} is off. Switch it on, wait for its Home screen, then refresh.": "{0} está apagado. Enciéndelo, espera a su pantalla de inicio y actualiza.",
    "{0} did not list its apps. A TV that just woke is slow to: try again once its Home screen shows.": "{0} no ha listado sus apps. Un televisor recién despertado tarda en hacerlo: vuelve a intentarlo cuando aparezca su pantalla de inicio.",
    "an IPv4 address is required": "se necesita una dirección IPv4",
    "No MAC address found for that IP. Make sure the TV is on.": "No se ha encontrado ninguna dirección MAC para esa IP. Comprueba que el televisor está encendido.",
    "{0}. Is the TV on?": "{0}. ¿Está encendido el televisor?",
    "No app is in the foreground. Open the app on the TV, then try again.": "No hay ninguna app en primer plano. Abre la app en el televisor y vuelve a intentarlo.",
    "A valid MAC address is required": "Se necesita una dirección MAC válida",
    "unknown key": "tecla desconocida",
    "the TV did not take the key": "el televisor no ha aceptado la tecla",
    "Cannot reach the TV at {0}: is it on, and on this network? ({1})": "No se puede contactar con el televisor en {0}: ¿está encendido y en esta red? ({1})",
    "no pairing in progress for that address; start again": "no hay ningún emparejamiento en curso para esa dirección; empieza de nuevo",
    "the pairing expired; start again": "el emparejamiento ha caducado; empieza de nuevo",
    "a 4-digit PIN is required": "se necesita un PIN de 4 dígitos",
    "the TV did not answer: {0}": "el televisor no ha respondido: {0}",
    "the TV refuses connections on port {0}": "el televisor rechaza las conexiones en el puerto {0}",
    "the TV answered HTTP {0}": "el televisor ha respondido HTTP {0}",
    "the TV refused the credentials: pair it again": "el televisor ha rechazado las credenciales: vuelve a emparejarlo",
    "unexpected answer from the TV: {0}": "respuesta inesperada del televisor: {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "el certificado del televisor ({0}) no es el fijado ({1})",
    "Invalid PIN code. Please check the PIN on your TV screen and try again.": "Código PIN incorrecto. Comprueba el PIN en la pantalla del televisor y vuelve a intentarlo.",
    "Access denied. The TV rejected the pairing request.": "Acceso denegado. El televisor ha rechazado la solicitud de emparejamiento.",
    "Pairing endpoint not found. Your TV may not support this pairing method.": "No se ha encontrado el punto de emparejamiento. Puede que tu televisor no admita este método.",
    "Request timeout. The TV took too long to respond.": "Tiempo de espera agotado. El televisor ha tardado demasiado en responder.",
    "TV internal error. Please try again.": "Error interno del televisor. Vuelve a intentarlo.",
    "TV is temporarily unavailable. Please try again later.": "El televisor no está disponible por ahora. Vuelve a intentarlo más tarde."
  },
  "pt": {
    "Pair your Philips Android TVs and control them from here and from the Home app.": "Emparelhe os seus televisores Philips Android TV e controle-os a partir daqui e da app Casa.",
    "Your TVs": "Os seus televisores",
    "Add a TV": "Adicionar um televisor",
    "On": "Ligado",
    "Off": "Desligado",
    "Standby": "Em espera",
    "Not responding": "Não responde",
    "Updates pushed by the TV": "Alterações enviadas pelo televisor",
    "Waiting for the TV's push": "À espera dos envios do televisor",
    "Polling for changes": "Consulta periódica de alterações",
    "Input": "Entrada",
    "Sound": "Som",
    "Muted": "Sem som",
    "In standby. Its input and Ambilight show once it is on.": "Em espera. A entrada e o Ambilight aparecem quando estiver ligado.",
    "Off, or not on the network. Wake sends a Wake-on-LAN packet.": "Desligado ou fora da rede. Despertar envia um pacote Wake-on-LAN.",
    "Remote for {name}": "Comando de {name}",
    "Turn off": "Desligar",
    "Wake": "Despertar",
    "{n} input": "{n} entrada",
    "{n} inputs": "{n} entradas",
    "Certificate pinned": "Certificado fixado",
    "Certificate not pinned, pair again to pin it": "Certificado não fixado, emparelhe novamente para o fixar",
    "Actions for {name}": "Ações de {name}",
    "Inputs": "Entradas",
    "Edit": "Editar",
    "Show its log": "Mostrar o registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my TV {name}: ": "Sobre o meu televisor {name}: ",
    "Remove": "Remover",
    "Follow video": "Seguir o vídeo",
    "Follow audio": "Seguir o áudio",
    "Follow color": "Seguir a cor",
    "Lounge light": "Luz ambiente",
    "No TV yet. Switch your TV on, then add it above.": "Ainda não há televisores. Ligue o televisor e adicione-o acima.",
    "Home": "Início",
    "Channel": "Canal",
    "App": "App",
    "Custom": "Personalizada",
    "Inputs of {name}": "Entradas de {name}",
    "Loading the inputs of {name}…": "A carregar as entradas de {name}…",
    "Discard the changes to the inputs?": "Descartar as alterações às entradas?",
    "Shown inputs, in order": "Entradas visíveis, por ordem",
    "Hidden inputs": "Entradas ocultas",
    "The order of the input wheel in the Home app. Drag a row by its handle, or press Alt and an arrow key. Click a name to rename it.": "A ordem da roda de entradas na app Casa. Arraste uma linha pela pega ou prima Alt e uma seta. Clique num nome para o mudar.",
    "Refresh from TV": "Atualizar a partir do televisor",
    "Read the TV's apps again": "Ler novamente as apps do televisor",
    "Close": "Fechar",
    "Shown · {n}": "Visíveis · {n}",
    "drag to reorder": "arraste para reordenar",
    "No input is shown.": "Nenhuma entrada está visível.",
    "Hidden · {n}": "Ocultas · {n}",
    "+ shows an input": "+ mostra uma entrada",
    "Every input is shown.": "Todas as entradas estão visíveis.",
    "Unsaved changes": "Alterações não guardadas",
    "Saved. The Home app shows this order.": "Guardado. A app Casa mostra esta ordem.",
    "Reset to the TV's order": "Repor a ordem do televisor",
    "Discard": "Descartar",
    "Save": "Guardar",
    "Name of {name}": "Nome de {name}",
    "Hide": "Ocultar",
    "Show": "Mostrar",
    "Hide {name}": "Ocultar {name}",
    "Show {name}": "Mostrar {name}",
    "The name the TV gives it": "O nome que o televisor lhe dá",
    "{name}. Press Alt and an arrow key to move it.": "{name}. Prima Alt e uma seta para a mover.",
    "Drag to reorder": "Arraste para reordenar",
    "{n} new input from the TV: {names}.": "{n} entrada nova do televisor: {names}.",
    "{n} new inputs from the TV: {names}.": "{n} entradas novas do televisor: {names}.",
    "The TV has no new app.": "O televisor não tem apps novas.",
    "Put the inputs of {name} back in the TV's order, all shown, with their own names?": "Repor as entradas de {name} na ordem do televisor, todas visíveis e com os nomes originais?",
    "Get MAC": "Obter MAC",
    "Enter the TV's IPv4 address first.": "Introduza primeiro o endereço IPv4 do televisor.",
    "Source switches": "Interruptores de fonte",
    "Ambilight + Hue switch": "Interruptor Ambilight + Hue",
    "Power sensor: motion while the TV is on": "Sensor de energia: movimento enquanto o televisor está ligado",
    "Ambilight sensor: motion while Ambilight is on": "Sensor Ambilight: movimento enquanto o Ambilight está ligado",
    "Mute sensor: motion while the sound is muted": "Sensor de silêncio: movimento enquanto o som está cortado",
    "Edit {name}": "Editar {name}",
    "Loading {name}…": "A carregar {name}…",
    "This TV is not in the configuration.": "Este televisor não está na configuração.",
    "Discard the changes to this TV?": "Descartar as alterações a este televisor?",
    "Saved": "Guardado",
    "General": "Geral",
    "Remote": "Comando",
    "Automations": "Automatizações",
    "Apps": "Apps",
    "Buttons": "Botões",
    "Name in the Home app": "Nome na app Casa",
    "Address": "Endereço",
    "The TV's IPv4 address. Give it a fixed address in your router.": "O endereço IPv4 do televisor. Atribua-lhe um endereço fixo no router.",
    "MAC address": "Endereço MAC",
    "For Wake-on-LAN, which switches the TV on from deep standby.": "Para o Wake-on-LAN, que liga o televisor a partir do modo de espera profundo.",
    "Ambilight style": "Estilo do Ambilight",
    "Polling interval (ms)": "Intervalo de consulta (ms)",
    "Switch Ambilight on whenever the TV comes on": "Ligar o Ambilight sempre que o televisor se ligar",
    "Pairing": "Emparelhamento",
    "Paired, with the TV's certificate pinned. Pair again after a reset of the TV, when it refuses Homeswift.": "Emparelhado, com o certificado do televisor fixado. Emparelhe novamente após uma reposição do televisor, se este recusar o Homeswift.",
    "Paired without a pinned certificate. Pair again to pin it.": "Emparelhado sem certificado fixado. Emparelhe novamente para o fixar.",
    "Pair again": "Emparelhar novamente",
    "Saving applies at once: the TV keeps its place in the Home app.": "Ao guardar, as alterações aplicam-se de imediato: o televisor mantém o seu lugar na app Casa.",
    "Found by the plugin when left empty": "Encontrada pelo plugin se ficar vazia",
    "Detect from TV": "Detetar no televisor",
    "Asking the TV which app is open…": "A perguntar ao televisor que app está aberta…",
    "Found {name}.": "Encontrada: {name}.",
    "Add app": "Adicionar app",
    "An app needs a name and a package name.": "Uma app precisa de um nome e de um nome de pacote.",
    "No custom app.": "Nenhuma app personalizada.",
    "Add an app": "Adicionar uma app",
    "Name": "Nome",
    "Package name": "Nome do pacote",
    "Launch activity (optional)": "Atividade de arranque (opcional)",
    "Power menu": "Menu de energia",
    "Add button": "Adicionar botão",
    "A button needs a name.": "Um botão precisa de um nome.",
    "Sends {key}": "Envia {key}",
    "No custom button.": "Nenhum botão personalizado.",
    "Add a button": "Adicionar um botão",
    "Remote key": "Tecla do comando",
    "Each key can be used by one button only.": "Cada tecla só pode ser usada por um botão.",
    "The TV needs a name.": "O televisor precisa de um nome.",
    "The address must be an IPv4 address, like 192.168.1.20.": "O endereço tem de ser IPv4, como 192.168.1.20.",
    "The MAC address must look like AA:BB:CC:DD:EE:FF.": "O endereço MAC tem de ter a forma AA:BB:CC:DD:EE:FF.",
    "Remove {name}? It leaves the Home app, with its scenes and automations.": "Remover {name}? Sai da app Casa, com as suas cenas e automatizações.",
    "Find": "Procurar",
    "PIN": "PIN",
    "Confirm": "Confirmar",
    "Done": "Concluído",
    "Wake {name}": "Despertar {name}",
    "Sent. Give {name} a few seconds to start, then pair again.": "Enviado. Aguarde uns segundos até {name} arrancar e emparelhe novamente.",
    "TV address": "Endereço do televisor",
    "Find TVs": "Procurar televisores",
    "Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds.": "Ligue o televisor: tem de estar ligado e nesta rede. O Homeswift procura-o durante cinco segundos.",
    "or enter its address": "ou introduza o endereço",
    "Pair": "Emparelhar",
    "PIN digit {n}": "Dígito {n} do PIN",
    "Confirm PIN": "Confirmar PIN",
    "Cancel": "Cancelar",
    "Living Room TV": "Televisor da sala",
    "Ambilight style when switched on from HomeKit": "Estilo do Ambilight ao ligar a partir do HomeKit",
    "Remote and automations": "Comando e automatizações",
    "Add TV": "Adicionar televisor",
    "The entry for config.json": "A entrada para o config.json",
    "Copy": "Copiar",
    "Copied.": "Copiado.",
    "Add another TV": "Adicionar outro televisor",
    "Looking for TVs…": "A procurar televisores…",
    "Every TV that answered is already added.": "Todos os televisores que responderam já estão adicionados.",
    "No TV announced itself. Check it is on, or enter its address.": "Nenhum televisor se anunciou. Verifique se está ligado ou introduza o endereço.",
    "Enter the TV's IPv4 address, like 192.168.1.20.": "Introduza o endereço IPv4 do televisor, como 192.168.1.20.",
    "Asking the TV for a PIN…": "A pedir um PIN ao televisor…",
    "Type the PIN {name} shows on screen.": "Introduza o PIN que {name} mostra no ecrã.",
    "The TV answered over plain HTTP, so its certificate cannot be pinned.": "O televisor respondeu por HTTP simples, por isso o certificado não pode ser fixado.",
    "The PIN has four digits.": "O PIN tem quatro dígitos.",
    "{name} is paired again, with its certificate pinned.": "{name} foi emparelhado novamente, com o certificado fixado.",
    "{name} is paired again.": "{name} foi emparelhado novamente.",
    "Paired, and the TV's certificate is pinned.": "Emparelhado, e o certificado do televisor está fixado.",
    "Paired.": "Emparelhado.",
    "The TV did not give it. Its network settings show it (Settings › Network › View network settings).": "O televisor não o indicou. As definições de rede mostram-no (Definições › Rede › Ver definições de rede).",
    "A MAC address is needed to switch the TV on.": "É necessário um endereço MAC para ligar o televisor.",
    "{name} is added. In the Home app, add it with the bridge's setup code: Add Accessory › More options, then the TV's name.": "{name} foi adicionado. Na app Casa, adicione-o com o código de configuração da ponte: Adicionar acessório › Mais opções e depois o nome do televisor.",
    "no TV with that MAC": "não há nenhum televisor com esse MAC",
    "The inputs are listed in the configuration (inputs), so the TV's apps are not read.": "As entradas estão na configuração (inputs), por isso as apps do televisor não são lidas.",
    "{0} is off. Switch it on, wait for its Home screen, then refresh.": "{0} está desligado. Ligue-o, aguarde pelo ecrã inicial e atualize.",
    "{0} did not list its apps. A TV that just woke is slow to: try again once its Home screen shows.": "{0} não listou as apps. Um televisor que acabou de despertar demora a fazê-lo: tente novamente quando o ecrã inicial aparecer.",
    "an IPv4 address is required": "é necessário um endereço IPv4",
    "No MAC address found for that IP. Make sure the TV is on.": "Não foi encontrado nenhum endereço MAC para esse IP. Verifique se o televisor está ligado.",
    "{0}. Is the TV on?": "{0}. O televisor está ligado?",
    "No app is in the foreground. Open the app on the TV, then try again.": "Nenhuma app está em primeiro plano. Abra a app no televisor e tente novamente.",
    "A valid MAC address is required": "É necessário um endereço MAC válido",
    "unknown key": "tecla desconhecida",
    "the TV did not take the key": "o televisor não aceitou a tecla",
    "Cannot reach the TV at {0}: is it on, and on this network? ({1})": "Não é possível contactar o televisor em {0}: está ligado e nesta rede? ({1})",
    "no pairing in progress for that address; start again": "não há nenhum emparelhamento em curso para esse endereço; comece de novo",
    "the pairing expired; start again": "o emparelhamento expirou; comece de novo",
    "a 4-digit PIN is required": "é necessário um PIN de 4 dígitos",
    "the TV did not answer: {0}": "o televisor não respondeu: {0}",
    "the TV refuses connections on port {0}": "o televisor recusa ligações na porta {0}",
    "the TV answered HTTP {0}": "o televisor respondeu HTTP {0}",
    "the TV refused the credentials: pair it again": "o televisor recusou as credenciais: emparelhe-o novamente",
    "unexpected answer from the TV: {0}": "resposta inesperada do televisor: {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "o certificado do televisor ({0}) não é o fixado ({1})",
    "Invalid PIN code. Please check the PIN on your TV screen and try again.": "Código PIN inválido. Verifique o PIN no ecrã do televisor e tente novamente.",
    "Access denied. The TV rejected the pairing request.": "Acesso negado. O televisor rejeitou o pedido de emparelhamento.",
    "Pairing endpoint not found. Your TV may not support this pairing method.": "Endpoint de emparelhamento não encontrado. O televisor pode não suportar este método.",
    "Request timeout. The TV took too long to respond.": "Tempo esgotado. O televisor demorou demasiado a responder.",
    "TV internal error. Please try again.": "Erro interno do televisor. Tente novamente.",
    "TV is temporarily unavailable. Please try again later.": "O televisor está temporariamente indisponível. Tente novamente mais tarde."
  }
});

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
  .tv.redrawn { animation: none; }
  .tv-head { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .tv-head .who { flex: 1; min-width: 0; }
  .tv-head strong { display: block; font-size: 1.0625rem; letter-spacing: -0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tv-head .muted { font-size: 0.8125rem; font-variant-numeric: tabular-nums; letter-spacing: 0.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  .off-note { margin: 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }

  .tv-foot { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; padding-top: 12px; border-top: 1px solid var(--line); font-size: 0.8125rem; }
  .tv-foot .menu-button { margin-left: auto; }
  .tv-foot a { color: var(--accent); text-decoration: none; font-weight: 500; }

  /* The inputs editor: a panel with two columns like the Homebridge plugin's, shown (ordered) and hidden. */
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
  /* The pairing wizard opens under its button, above the TVs, as the material arriving. */
  .pairing { margin-bottom: 16px; animation: materialize var(--normal) var(--ease-out); scroll-margin-top: 90px; }
  .pairing .panel-head { margin-bottom: 14px; }
  .pairing .panel-head h2 { margin: 0; }
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
  /* A MAC address field with its "Get MAC" button. */
  .with-button { display: flex; gap: 8px; align-items: center; }
  .with-button input { flex: 1; min-width: 0; }
  .head-actions { display: flex; gap: 14px; align-items: center; flex-shrink: 0; }
  .check { display: flex; align-items: center; gap: 12px; margin: 14px 0 0; }
  .check label { margin: 0; }
  .needs { border-color: var(--warn) !important; }
  details { margin-top: 14px; }
  details pre { font-family: var(--mono); font-size: 0.78rem; margin: 6px 0 0; padding: 12px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); overflow: auto; }

  @media (prefers-reduced-motion: reduce) {
    .tv, .step, .pairing { animation: none; }
    .source { transition: none; }
  }
  @media (max-width: 640px) {
    .form { grid-template-columns: 1fr; }
    .original { display: none; }
    .pin input { width: 48px; height: 56px; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-blue" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8.5 20.5h7"/></svg></span>
    <div>
      <h1>Philips Ambilight TV</h1>
      <p class="muted" data-i18n>Pair your Philips Android TVs and control them from here and from the Home app.</p>
    </div>
  </div>

  <div class="section-head"><h2 data-i18n>Your TVs</h2><button id="add-tv" class="primary" data-i18n aria-expanded="false" aria-controls="pairing" data-action-icon="plus">Add a TV</button></div>
  <section id="pairing" class="card pairing hidden" aria-labelledby="add-title"></section>
  <div id="tvs" class="tvs"></div>
  <div id="sources" class="card panel hidden"></div>
  <div id="tv-editor" class="card panel hidden"></div>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="/remote.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
