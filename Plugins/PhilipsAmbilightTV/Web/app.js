// The Philips Ambilight TV page: the TVs the plugin instance knows, refreshed every two seconds while the
// page is visible, with a remote, their inputs and an editor of their settings. A TV is found and paired on
// Add accessories (Setup): the page leads there.
(() => {
  "use strict";
  const {
    $, el, tile, request, platform, name: instance, explain, breadcrumb, api, act,
    readBlock, updateBlock, setKey, poll, renderKeyed, canonicalMAC, isMAC, sameMAC, setupCard, setupAddress,
  } = homeswift;
  const { t, tn } = HomeswiftI18n;

  // MARK: A TV's entry: in the block's `devices` (the Homebridge plugin's list), or its Accessory Settings
  // (`_accessories`, by its MAC) once Setup paired it. Both hold the same settings; a TV Setup paired keeps its MAC,
  // which keys its keys in the vault.

  const accessoryKey = (block, mac) => Object.keys(block._accessories || {}).find((key) => sameMAC(key, mac));

  /// The TV's entry, with `setUp` when it lives in its Accessory Settings; null when the block has neither.
  async function findDevice(mac) {
    const block = await readBlock();
    const listed = (block.devices || []).find((device) => sameMAC(device.mac, mac));
    if (listed) return { entry: listed, setUp: false };
    const key = accessoryKey(block, mac);
    if (!key) return null;
    const { excluded, parts, ...settings } = block._accessories[key];
    return { entry: { ...settings, mac: key }, setUp: true };
  }

  /// Changes the TV's entry: `change` edits it in place, or returns its replacement.
  function updateDevice(mac, change) {
    return updateBlock((block) => {
      const devices = block.devices || [];
      const index = devices.findIndex((device) => sameMAC(device.mac, mac));
      if (index >= 0) {
        devices[index] = change(devices[index]) ?? devices[index];
        return;
      }
      const key = accessoryKey(block, mac);
      if (!key) throw new Error(t("This TV is not in the configuration."));
      const { excluded, parts, ...settings } = block._accessories[key];
      const draft = { ...settings, mac: key };
      const { mac: _, ...changed } = change(draft) ?? draft;
      block._accessories[key] = { ...changed, ...(excluded ? { excluded } : {}), ...(parts ? { parts } : {}) };
    });
  }

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

  // The editor's Remote and Automations sections.
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
      const [schema, found] = await Promise.all([deviceSchema(), findDevice(tv.mac)]);
      if (!found) throw new Error(t("This TV is not in the configuration."));
      editorState = { tv, schema, setUp: found.setUp, draft: structuredClone(found.entry), saved: JSON.stringify(found.entry), section: "general" };
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
          // A TV Setup paired goes by its MAC, which keys its keys in the vault: it stays as Setup read it.
          editorState.setUp
            ? fieldRow(t("MAC address"), el("input", { type: "text", value: draft.mac, readOnly: true }), t("Read from the TV when it was paired. For Wake-on-LAN, which switches the TV on from deep standby."))
            : fieldRow(t("MAC address"), (() => {
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
          el("a", { class: "button", href: setupAddress(), actionIcon: "restore", text: t("Pair again") })));
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
    await updateDevice(tv.mac, () => structuredClone(draft));
    editorState.saved = JSON.stringify(draft);
    editorState.tv = { ...tv, name: draft.name, mac: draft.mac };
    renderEditor();
    setTimeout(refresh, 600);
  }

  async function removeTV(tv) {
    if (!await HomeswiftCommon.confirmDialog(t("Remove {name}? It leaves the Home app, with its scenes and automations.", { name: tv.name }))) return;
    if (editingTV(tv) && (!(await closeSources()) || !(await closeEditor()))) return;
    const found = await findDevice(tv.mac);
    if (found?.setUp) {
      // Paired through Setup: Excluded, as Add accessories does it, which can include it again.
      await api("/api/setup/exclude", { method: "POST", body: { platform, name: instance, deviceID: found.entry.mac, excluded: true } });
    } else {
      await updateBlock((block) => {
        block.devices = (block.devices || []).filter((device) => !sameMAC(device.mac, tv.mac));
        if (!block.devices.length) delete block.devices;
      });
    }
    await refresh();
  }
  const editingTV = (tv) => (editing && sameMAC(editing.tv.mac, tv.mac)) || (editorState && sameMAC(editorState.tv.mac, tv.mac));

  // MARK: Adding a TV: Add accessories finds it (or takes the address in its settings) and pairs it with its PIN.

  $("#setup").replaceChildren(setupCard({
    title: t("Add a TV"),
    text: t("Add accessories finds the Philips TVs on this network and pairs them with the PIN they show. Switch the TV on first."),
    glyph: "pair", tone: "blue", start: false,
  }));

  poll(refresh);
})();
