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
            : el("button", { class: "primary", text: t("Wake"), onclick: (event) => act(event.currentTarget, () => request(`wake?mac=${encodeURIComponent(tv.mac)}`, { method: "POST" })) }),
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
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => removeTV(tv).catch((e) => alert(e.message)) },
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
    if (!closeEditor()) return;
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
  function closeSources() {
    if (editing && isDirty() && !confirm(t("Discard the changes to the inputs?"))) return false;
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
          el("button", { class: "link", text: t("Refresh from TV"), title: t("Read the TV's apps again"), onclick: (event) => act(event.currentTarget, refreshSources) }),
          el("button", { class: "link", text: t("Close"), onclick: closeSources }))),
      el("div", { class: "panel-columns" },
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status on", text: t("Shown · {n}", { n: shown.length }) }), el("span", { class: "muted", text: t("drag to reorder") })),
          shown.length ? shownList : el("p", { class: "muted empty-list", text: t("No input is shown.") })),
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status standby", text: t("Hidden · {n}", { n: hidden.length }) }), el("span", { class: "muted", text: t("+ shows an input") })),
          hidden.length ? hiddenList : el("p", { class: "muted empty-list", text: t("Every input is shown.") }))),
      el("div", { class: `save-bar ${dirty ? "dirty" : ""}` },
        el("span", { class: "muted", text: dirty ? t("Unsaved changes") : t("Saved. The Home app shows this order.") }),
        el("button", { class: "link", text: t("Reset to the TV's order"), onclick: (event) => act(event.currentTarget, resetSources) }),
        el("button", { text: t("Discard"), disabled: !dirty, onclick: () => { editing.sources = JSON.parse(editing.saved); renderSources(); } }),
        el("button", { class: "primary", text: t("Save"), disabled: !dirty, onclick: (event) => act(event.currentTarget, saveSources) })));
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
    if (!confirm(t("Put the inputs of {name} back in the TV's order, all shown, with their own names?", { name: editing.tv.name }))) return;
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
    return el("button", { type: "button", text: t("Get MAC"), onclick: (event) => {
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
    if (!closeSources() || !closeEditor()) return;
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
  function closeEditor() {
    if (editorState && JSON.stringify(editorState.draft) !== editorState.saved && !confirm(t("Discard the changes to this TV?"))) return false;
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
    const save = el("button", { class: "primary", text: t("Save"), onclick: (event) => act(event.currentTarget, saveEditor, report) });
    const discard = el("button", { text: t("Discard"), onclick: () => { editorState.draft = JSON.parse(editorState.saved); renderEditor(); } });
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
          el("button", { text: t("Pair again"), onclick: () => { if (closeEditor()) repair(tv); } })));
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
        el("button", { class: "link", text: t("Close"), onclick: closeEditor })),
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
    const detect = el("button", { text: t("Detect from TV"), onclick: (event) => act(event.currentTarget, async () => {
      status.className = "status-line muted";
      status.textContent = t("Asking the TV which app is open…");
      const { app } = await request(`current-app?mac=${encodeURIComponent(editorState.tv.mac)}`);
      packageName.value = app.packageName;
      className.value = app.className ?? "";
      if (!appName.value) appName.value = app.name ?? "";
      status.className = "status-line ok";
      status.textContent = t("Found {name}.", { name: app.packageName });
    }, (text) => { status.className = "status-line error"; status.replaceChildren(text); }) });
    const add = el("button", { class: "primary", text: t("Add app"), onclick: () => {
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
        el("button", { class: "link danger", text: t("Remove"), onclick: () => { setKey(draft, "customApps", apps.filter((a) => a !== app).length ? apps.filter((a) => a !== app) : undefined); changed(); } }))))
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
    const add = el("button", { class: "primary", text: t("Add button"), disabled: key.options.length === 0, onclick: () => {
      if (!buttonName.value.trim()) { status.className = "status-line error"; status.textContent = t("A button needs a name."); return; }
      draft.customButtons = [...buttons, { name: buttonName.value.trim(), key: key.value }];
      changed();
    } });
    return el("div", {},
      el("p", { class: "help", text: schema.customButtons.description }),
      buttons.length ? el("ul", { class: "entries" }, buttons.map((button) => el("li", {},
        el("div", {}, el("strong", { text: button.name }), el("div", { class: "muted", text: t("Sends {key}", { key: button.key }) })),
        el("button", { class: "link danger", text: t("Remove"), onclick: () => { setKey(draft, "customButtons", buttons.filter((b) => b !== button).length ? buttons.filter((b) => b !== button) : undefined); changed(); } }))))
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
    if (!confirm(t("Remove {name}? It leaves the Home app, with its scenes and automations.", { name: tv.name }))) return;
    if (editingTV(tv) && (!closeSources() || !closeEditor())) return;
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
      sleeper ? el("button", { class: "link", text: t("Wake {name}", { name: sleeper.name }), onclick: (event) => act(event.currentTarget, async () => {
        const address = sleeper.mac ?? (await request(`mac?ip=${encodeURIComponent(sleeper.ip)}`)).mac;
        await request("wake", { method: "POST", body: { mac: address, ip: sleeper.ip } });
        say(t("Sent. Give {name} a few seconds to start, then pair again.", { name: sleeper.name }), "ok");
      }, fail) }) : null,
      explain({ error: message, context: "Pairing a Philips Android TV from the Homeswift plugin page: POST pair/request on port 1926, the TV shows a PIN, then pair/grant with an HMAC of the PIN.", device: { model: "Philips Android TV with Ambilight" } }));
  }

  // Step 1: find the TV, or type its address.
  const found = el("div", { class: "found" });
  const address = el("input", { type: "text", placeholder: "192.168.1.20", inputmode: "decimal", autocomplete: "off", spellcheck: false, "aria-label": t("TV address") });
  const findButton = el("button", { text: t("Find TVs"), onclick: (event) => act(event.currentTarget, discover, fail) });
  const find = el("div", { class: "step" },
    el("p", { class: "muted", text: t("Switch the TV on: it has to be on and on this network. Homeswift looks for it for five seconds.") }),
    findButton, found,
    el("div", { class: "or", text: t("or enter its address") }),
    el("form", { class: "manual", onsubmit: (event) => { event.preventDefault(); act(event.submitter ?? manualPair, () => pair({ ip: address.value.trim() }), fail); } },
      address, el("button", { type: "submit", text: t("Pair") })));
  const manualPair = find.querySelector(".manual button");

  // Step 2: the PIN the TV shows, a box per digit.
  const digits = [0, 1, 2, 3].map((i) => el("input", { type: "text", inputmode: "numeric", maxlength: 1, autocomplete: i === 0 ? "one-time-code" : "off", "aria-label": t("PIN digit {n}", { n: i + 1 }) }));
  const pinPrompt = el("p", {});
  const confirmPin = el("button", { class: "primary", text: t("Confirm PIN"), onclick: (event) => act(event.currentTarget, grant, fail) });
  const pinStep = el("div", { class: "step" },
    pinPrompt, el("div", { class: "pin" }, digits),
    el("div", { class: "actions" }, confirmPin, el("button", { class: "link", text: t("Cancel"), onclick: reset })));

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
      el("button", { class: "primary", text: t("Add TV"), onclick: (event) => act(event.currentTarget, addToConfiguration, fail) }),
      el("button", { class: "link", text: t("Cancel"), onclick: reset })),
    el("details", {}, el("summary", { text: t("The entry for config.json") }), entryText,
      el("button", { class: "link", text: t("Copy"), onclick: (event) => act(event.currentTarget, async () => { await HomeswiftCommon.copyText(entryText.textContent); say(t("Copied."), "ok"); }, fail) })));

  // After saving: the plugin reloads with the TV at once.
  const doneText = el("p", {});
  const done = el("div", { class: "step" },
    doneText,
    el("div", { class: "actions" }, el("button", { class: "primary", text: t("Done"), onclick: closePairing }), el("button", { text: t("Add another TV"), onclick: reset })));

  const bodies = [find, pinStep, confirmStep, done];
  pairing.replaceChildren(
    el("div", { class: "panel-head" }, el("h2", { id: "add-title", text: t("Add a TV") }), el("button", { class: "link", text: t("Close"), onclick: closePairing })),
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
      el("button", { class: "primary", text: t("Pair"), onclick: (event) => act(event.currentTarget, () => pair({ ip: tv.host, name: tv.name }), fail) }))));
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
