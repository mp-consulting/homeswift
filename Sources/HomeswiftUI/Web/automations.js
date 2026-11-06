// The Automations page (/automations, beside Scenes): what the bridge does on its own, a Trigger, Conditions and Steps
// run in order (GLOSSARY.md). Its list with each one's triggers, last run, On and Run; the Assistant's draft from a
// sentence, opened in the editor to review; the editor (/automations/<id>, /automations/new).
(() => {
  "use strict";

  const { t, tn } = HomeswiftI18n;
  const { el, api } = HomeswiftCommon;
  const app = () => window.HomeswiftApp;
  const home = () => window.HomeswiftHome.editor;
  const dateTimeFormat = new Intl.DateTimeFormat(HomeswiftI18n.locale, { dateStyle: "medium", timeStyle: "short" });

  /// What the editor opens with next, instead of an empty Automation: the Assistant's draft, or a Scene to apply.
  let pending = null;
  /// Opens the editor on a new Automation filled with `draft`.
  function draft(value) {
    pending = value;
    app().navigate("/automations/new");
  }

  const stepKinds = [["scene", t("Apply a scene"), "play"], ["set", t("Set a value"), "sliders"], ["wait", t("Wait"), "history"],
    ["waitUntil", t("Wait until"), "sensor"], ["notify", t("Notify"), "bell"], ["tool", t("Plugin action"), "plugin"]];

  async function view(main, [id] = []) {
    if (id) return editor(main, id);
    const data = await api("/api/automations");
    const accessories = await api("/api/accessories").catch(() => []);
    const names = new Map(accessories.map((one) => [one.id, window.HomeswiftHome.displayName(one)]));
    const admin = app().isAdmin();
    const newButton = admin ? el("a", { class: "button primary", href: "/automations/new", actionIcon: "plus", text: t("New automation") }) : null;
    const cards = data.automations.map((automation) => card(automation, names, admin));
    const empty = el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("workflow")),
      el("p", { class: "muted", text: t("No automation yet. One turns the hall light on when there is motion, then off five minutes later; or closes the blinds at sunset on weekdays.") }), newButton);
    app().show(main,
      app().pageHead(t("Automations"), t("What the bridge does on its own: when a trigger fires and the conditions hold, its steps run in order. Locks, garage doors and alarms are never changed by an automation."),
        cards.length ? newButton : null),
      window.HomeswiftHome.scenesTabs("automations"),
      admin && data.assistant ? draftCard() : null,
      cards.length ? el("div", { class: "automation-list" }, cards) : empty);
  }

  /// A sentence for the Assistant, whose draft opens in the editor: nothing is saved before the person does.
  function draftCard() {
    const sentence = el("input", { type: "text", maxLength: 500, required: true, placeholder: t("When the front door opens after sunset, turn the hall light on for five minutes"),
      "aria-label": t("What should happen") });
    const line = home().statusLine();
    const ask = el("button", { type: "submit", actionIcon: "sparkle", text: t("Draft it") });
    return el("form", { class: "card automation-draft", onsubmit: async (event) => {
      event.preventDefault();
      await HomeswiftCommon.busyButton(ask, async () => {
        home().say(line, t("The Assistant is writing it…"));
        const answer = await api("/api/automations/draft", { method: "POST", body: { sentence: sentence.value.trim() } });
        draft({ ...(answer.automation ?? answer.draft), problem: answer.problem });
      }, { report: (e) => home().say(line, e.message, "error") });
    } },
      el("div", { class: "who" }, el("strong", { text: t("Describe it") }), el("p", { class: "muted", text: t("The Assistant drafts the automation; you review it before saving.") })),
      el("div", { class: "automation-draft-row" }, sentence, ask), line);
  }

  function lastRun(automation) {
    if (automation.lastSkipped && (!automation.lastRun || automation.lastSkipped.at > automation.lastRun.at)) {
      return t("Skipped {date}: {reason}", { date: dateTimeFormat.format(new Date(automation.lastSkipped.at)), reason: HomeswiftI18n.message(automation.lastSkipped.reason) });
    }
    if (!automation.lastRun) return t("Never run");
    const vars = { date: dateTimeFormat.format(new Date(automation.lastRun.at)), trigger: automation.lastRun.trigger };
    const text = automation.lastRun.ok ? t("Last run {date} ({trigger})", vars) : t("Last run {date} ({trigger}), with errors", vars);
    return automation.lastRun.reason ? `${text} · ${HomeswiftI18n.message(automation.lastRun.reason)}` : text;
  }

  function card(automation, names, admin) {
    const { describeTrigger, triggerIcons } = home();
    const first = automation.triggers[0];
    const status = el("p", { class: "muted automation-last-run", text: lastRun(automation) });
    const enabled = el("input", { type: "checkbox", role: "switch", checked: automation.enabled, disabled: !admin, "aria-label": t("{name}: on", { name: automation.name }) });
    enabled.addEventListener("change", async () => {
      try { await api(`/api/automations/${encodeURIComponent(automation.id)}`, { method: "PUT", body: { name: automation.name, enabled: enabled.checked } }); }
      catch (e) { enabled.checked = !enabled.checked; HomeswiftCommon.showAlert(e.message); }
    });
    const run = el("button", { type: "button", actionIcon: "play", text: t("Run now"), onclick: async () => {
      await HomeswiftCommon.busyButton(run, async () => {
        const answer = await api(`/api/automations/${encodeURIComponent(automation.id)}/run`, { method: "POST", body: {} });
        if (answer.lastRun) status.textContent = lastRun({ ...automation, lastRun: answer.lastRun, lastSkipped: null });
      }, { report: (e) => HomeswiftCommon.showAlert(e.message) });
    } });
    return el("article", { class: "card automation-card" },
      el("div", { class: "automation-head" },
        el("span", { class: "tile tone-violet", "aria-hidden": "true" }, HomeswiftCommon.icon(triggerIcons[first?.type] ?? "workflow")),
        el("div", { class: "who" }, el("strong", { text: automation.name }),
          el("span", { class: "muted", text: [automation.triggers.map((trigger) => describeTrigger(trigger, names)).join(" · "),
            tn("{n} step", "{n} steps", automation.steps.length), automation.mode === "single" ? t("Single") : null,
            automation.homeKit ? t("In the Home app") : null].filter(Boolean).join(" · ") })),
        el("label", { class: "toggle compact" }, el("span", { class: "switch" }, enabled, el("span")))),
      automation.security ? el("p", { class: "muted note" }, HomeswiftCommon.icon("lock"), el("span", { text: t("It watches or names a lock, a door or an alarm: those are never changed by it.") })) : null,
      status,
      el("div", { class: "actions start" }, run, admin ? el("a", { class: "button", href: `/automations/${encodeURIComponent(automation.id)}`, actionIcon: "edit", text: t("Edit") }) : null));
  }

  // ---- The editor

  async function editor(main, id) {
    const isNew = id === "new";
    const [data, accessories, scenes] = await Promise.all([api("/api/automations"), api("/api/accessories"), api("/api/scenes").catch(() => ({ scenes: [] }))]);
    const fromDraft = isNew ? pending : null;
    pending = null;
    const automation = isNew ? { name: "", triggers: [{ type: "time", at: "07:00" }], conditions: [], steps: [], mode: "restart", enabled: true, ...(fromDraft ?? {}) }
      : data.automations.find((one) => one.id === id);
    if (!automation) { app().show(main, el("p", { class: "error", text: t("No such automation.") })); return; }
    const { triggerRow, conditionRow, field, statusLine, say } = home();
    const remove = (row, label, list) => el("button", { type: "button", class: "danger scene-condition-remove", actionIcon: "trash", text: label, onclick: () => { list.delete(row); row.remove(); } });

    const name = el("input", { type: "text", value: automation.name ?? "", maxLength: 64, required: true, placeholder: t("Hall light on motion") });
    const enabled = el("input", { type: "checkbox", checked: automation.enabled !== false });
    const homeKit = el("input", { type: "checkbox", checked: Boolean(automation.homeKit) });
    const mode = el("select", {}, el("option", { value: "restart", text: t("Restart: a new trigger starts it again") }), el("option", { value: "single", text: t("Single: a new trigger is ignored while it runs") }));
    mode.value = automation.mode || "restart";
    const toggle = (input, title, help) => el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")),
      el("span", {}, el("span", { class: "field-title", text: title }), el("p", { class: "help", text: help })));

    const triggers = new Set(), conditions = new Set(), steps = [];
    const triggerList = el("div", { class: "editor-list" }), conditionList = el("div", { class: "editor-list" }), stepList = el("ol", { class: "editor-list automation-steps" });
    const addTrigger = (value) => {
      const row = triggerRow(accessories, value, (row, label) => remove(row, label, triggers));
      triggers.add(row);
      triggerList.append(row);
    };
    const addCondition = (value) => {
      const row = conditionRow(accessories, value, (row, label) => remove(row, label, conditions));
      conditions.add(row);
      conditionList.append(row);
    };
    const redraw = () => stepList.replaceChildren(...steps);
    const addStep = (value = { type: "set" }) => {
      const row = stepRow(value, { accessories, scenes: scenes.scenes ?? [], tools: data.tools ?? [] });
      const move = (by) => {
        const at = steps.indexOf(row), to = at + by;
        if (to < 0 || to >= steps.length) return;
        steps.splice(at, 1);
        steps.splice(to, 0, row);
        redraw();
        row.querySelector(by < 0 ? ".step-up" : ".step-down")?.focus();
      };
      row.append(el("div", { class: "step-tools" },
        el("button", { type: "button", class: "icon-button step-up", title: t("Move up"), "aria-label": t("Move up"), onclick: () => move(-1) }, HomeswiftCommon.icon("up")),
        el("button", { type: "button", class: "icon-button step-down", title: t("Move down"), "aria-label": t("Move down"), onclick: () => move(1) }, HomeswiftCommon.icon("down")),
        el("button", { type: "button", class: "danger scene-condition-remove", actionIcon: "trash", text: t("Delete step"), onclick: () => { steps.splice(steps.indexOf(row), 1); redraw(); } })));
      steps.push(row);
      redraw();
    };
    automation.triggers.forEach(addTrigger);
    (automation.conditions ?? []).forEach(addCondition);
    (automation.steps ?? []).forEach(addStep);

    const place = data.location ? t("Sunrise and sunset are for {place}.", { place: data.location.name || `${data.location.lat}, ${data.location.lon}` })
      : t("Sunrise and sunset need a location: set it on the Scenes page.");
    const section = (title, glyph, help, ...content) => el("section", { class: "card automation-section" },
      el("div", { class: "automation-section-head" }, el("span", { class: "tile tone-violet", "aria-hidden": "true" }, HomeswiftCommon.icon(glyph)),
        el("div", { class: "who" }, el("h3", { text: title }), el("p", { class: "muted", text: help }))), ...content);
    const line = statusLine();
    const save = el("button", { class: "primary", actionIcon: "check", type: "submit", text: isNew ? t("Create the automation") : t("Save") });
    const read = () => ({ name: name.value.trim(), enabled: enabled.checked, homeKit: homeKit.checked, mode: mode.value,
      triggers: [...triggers].map((row) => row.read()), conditions: [...conditions].map((row) => row.read()), steps: steps.map((row) => row.read()) });
    const snapshot = () => { try { return JSON.stringify(read()); } catch { return null; } };
    const initial = isNew && fromDraft ? null : snapshot();
    let saved = false;
    app().setLeaveGuard(async () => saved || snapshot() === initial || HomeswiftCommon.confirmDialog(t("Leave without saving the automation?")));
    const form = el("form", { class: "automation-editor", onsubmit: async (event) => {
      event.preventDefault();
      await HomeswiftCommon.busyButton(save, async () => {
        const body = read();
        await api(isNew ? "/api/automations" : `/api/automations/${encodeURIComponent(automation.id)}`, { method: isNew ? "POST" : "PUT", body });
        saved = true;
        app().navigate("/automations");
      }, { report: (e) => say(line, e.message, "error") });
    } },
      fromDraft ? el("p", { class: `card note ${fromDraft.problem ? "error" : ""}`, text: fromDraft.problem ? t("The Assistant's draft needs a change before it saves: {problem}", { problem: fromDraft.problem })
        : t("The Assistant's draft: check each part, then save it.") }) : null,
      el("div", { class: "card form-card" }, el("div", { class: "fields" }, field(t("Name"), name), field(t("Mode"), mode)),
        toggle(enabled, t("On"), t("Off, its triggers do nothing; Run now still runs it.")),
        toggle(homeKit, t("A switch in the Home app"), t("On the Homeswift Scenes accessory: the switch turns the automation on and off."))),
      section(t("Triggers"), "play", t("Any of these starts it. {place}", { place }), triggerList,
        el("button", { actionIcon: "plus", type: "button", text: t("Add a trigger"), onclick: () => addTrigger() })),
      section(t("Conditions"), "shield", t("A trigger's run goes ahead only when all of these hold. Run now ignores them."), conditionList,
        el("button", { actionIcon: "plus", type: "button", text: t("Add a condition"), onclick: () => addCondition({ type: "time", after: "sunset", before: "23:00" }) })),
      section(t("Steps"), "workflow", t("Run in order. Locks, garage doors and alarms are left out: the last run says so."), stepList,
        el("button", { actionIcon: "plus", type: "button", text: t("Add a step"), onclick: () => addStep() })),
      el("div", { class: "save-bar" }, save, el("a", { class: "button", actionIcon: "close", href: "/automations", text: t("Cancel") }),
        isNew ? null : el("span", { class: "spacer" }),
        isNew ? null : el("button", { actionIcon: "trash", type: "button", class: "danger", text: t("Delete"), onclick: async () => {
          if (!(await HomeswiftAdmin.confirmAction({ title: t("Delete the automation {name}?", { name: automation.name }), text: t("It stops running, and its switch leaves the Home app. Its scenes stay."), confirmLabel: t("Delete"), confirmIcon: "trash" }))) return;
          try { await api(`/api/automations/${encodeURIComponent(automation.id)}`, { method: "DELETE" }); saved = true; app().navigate("/automations"); } catch (e) { say(line, e.message, "error"); }
        } })),
      line);
    app().show(main, app().breadcrumb([t("Automations"), "/automations"], [isNew ? t("New automation") : automation.name]), form);
  }

  /// One Step: its kind and its fields. `.read()` gives what to save.
  function stepRow(step, { accessories, scenes, tools }) {
    const { characteristicPicker, readable, writable, operators, field } = home();
    const type = el("select", { "aria-label": t("Step") }, stepKinds.map(([value, text]) => el("option", { value, text })));
    type.value = step.type;
    const body = el("div", { class: "group-inline grow automation-step-fields" });
    const row = el("li", { class: "editor-row automation-step" }, field(t("Step"), type), body);
    const draw = (shown) => {
      switch (shown.type) {
        case "scene": {
          const scene = el("select", { "aria-label": t("Scene") }, scenes.map((one) => el("option", { value: one.id, text: one.name })));
          if (shown.scene && !scenes.some((one) => one.id === shown.scene)) scene.prepend(el("option", { value: shown.scene, text: t("{name} (gone)", { name: shown.name || shown.scene }) }));
          if (shown.scene) scene.value = shown.scene;
          body.replaceChildren(...[field(t("Scene"), scene), scenes.length ? null : el("p", { class: "muted", text: t("No scene yet: make one on the Scenes page.") })].filter(Boolean));
          row.readBody = () => ({ scene: scene.value });
          break;
        }
        case "set": {
          const pick = {};
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: shown.id, service: shown.service, characteristic: shown.characteristic, value: shown.value, list: writable });
          body.replaceChildren(field(t("Accessory"), accessory), field(t("Control"), kind), field(t("Value"), holder));
          row.readBody = () => ({ ...pick.read(), value: pick.value.read() });
          break;
        }
        case "wait": {
          const [amount, unit] = duration(shown.seconds ?? 300);
          body.replaceChildren(field(t("For"), amount), field(t("Unit"), unit));
          row.readBody = () => ({ seconds: Math.max(1, Math.round(Number(amount.value) || 1)) * Number(unit.value) });
          break;
        }
        case "waitUntil": {
          const pick = {};
          const operator = el("select", { "aria-label": t("Comparison") }, operators.map(([value, text]) => el("option", { value, text })));
          operator.value = shown.operator || "eq";
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: shown.id, service: shown.service, characteristic: shown.characteristic, value: shown.value, list: readable });
          const minutes = el("input", { type: "number", min: 1, max: 1440, step: 1, value: Math.max(1, Math.round((shown.seconds ?? 3600) / 60)), "aria-label": t("At most (minutes)") });
          body.replaceChildren(field(t("Accessory"), accessory), field(t("Control"), kind), field(t("Comparison"), operator), field(t("Value"), holder), field(t("At most (minutes)"), minutes));
          row.readBody = () => ({ ...pick.read(), operator: operator.value, value: pick.value.read(), seconds: Math.max(1, Math.round(Number(minutes.value) || 1)) * 60 });
          break;
        }
        case "notify": {
          const title = el("input", { type: "text", maxLength: 80, value: shown.title ?? "", placeholder: t("The automation's name") });
          const message = el("textarea", { rows: 2, maxLength: 500, required: true, value: shown.message ?? "" });
          message.value = shown.message ?? "";
          const buttons = buttonsEditor(shown.buttons ?? [], { accessories, scenes });
          body.replaceChildren(field(t("Title"), title), field(t("Message"), message, t("Sent through the channels on the Notifications page.")), buttons);
          row.readBody = () => ({ ...(title.value.trim() ? { title: title.value.trim() } : {}), message: message.value.trim(), ...(buttons.read().length ? { buttons: buttons.read() } : {}) });
          break;
        }
        case "tool": {
          const tool = el("select", { "aria-label": t("Plugin action") }, tools.map((one) => el("option", { value: one.name, text: `${one.title} · ${one.plugin}` })));
          if (shown.tool && !tools.some((one) => one.name === shown.tool)) tool.prepend(el("option", { value: shown.tool, text: t("{name} (gone)", { name: shown.tool }) }));
          if (shown.tool) tool.value = shown.tool;
          const fields = el("div", { class: "fields automation-tool-fields" });
          let readArguments = () => ({});
          const fill = (values = {}) => {
            const chosen = tools.find((one) => one.name === tool.value);
            const built = chosen ? schemaFields(chosen.inputSchema, values) : { nodes: [], read: () => values };
            fields.replaceChildren(...(chosen ? [el("p", { class: "help", text: chosen.description })] : []), ...built.nodes);
            readArguments = built.read;
          };
          tool.addEventListener("change", () => fill());
          fill(shown.arguments ?? {});
          body.replaceChildren(tools.length ? field(t("Plugin action"), tool) : el("p", { class: "muted", text: t("No running plugin offers an action an automation may call.") }), fields);
          row.readBody = () => ({ tool: tool.value, arguments: readArguments() });
          break;
        }
      }
    };
    draw(step);
    type.addEventListener("change", () => draw({ type: type.value }));
    row.read = () => ({ type: type.value, ...row.readBody() });
    return row;
  }

  /// A Notify Step's buttons, three at most: each applies a scene, sets a value or opens a page. `.read()` gives them.
  function buttonsEditor(initial, { accessories, scenes }) {
    const { characteristicPicker, writable, field } = home();
    const rows = [];
    const list = el("div", { class: "notify-buttons" });
    const add = el("button", { type: "button", actionIcon: "plus", text: t("Add a button") });
    const refresh = () => { list.replaceChildren(...rows); add.hidden = rows.length >= 3; };
    const addRow = (button = { type: "scene", label: "" }) => {
      const label = el("input", { type: "text", maxLength: 40, required: true, value: button.label ?? "", placeholder: t("Turn it off") });
      const type = el("select", { "aria-label": t("Button") }, el("option", { value: "scene", text: t("Apply a scene") }), el("option", { value: "set", text: t("Set a value") }),
        el("option", { value: "open", text: t("Open a page") }));
      type.value = button.type;
      const fields = el("div", { class: "group-inline grow" });
      const row = el("div", { class: "notify-button" }, field(t("Button label"), label), field(t("Button"), type), fields,
        el("button", { type: "button", class: "danger scene-condition-remove", actionIcon: "trash", text: t("Delete button"), onclick: () => { rows.splice(rows.indexOf(row), 1); refresh(); } }));
      const draw = (shown) => {
        if (shown.type === "scene") {
          const scene = el("select", { "aria-label": t("Scene") }, scenes.map((one) => el("option", { value: one.id, text: one.name })));
          if (shown.scene) scene.value = shown.scene;
          fields.replaceChildren(field(t("Scene"), scene));
          row.readBody = () => ({ scene: scene.value });
        } else if (shown.type === "set") {
          const pick = {};
          const [accessory, kind, holder] = characteristicPicker(accessories, pick, { id: shown.id, service: shown.service, characteristic: shown.characteristic, value: shown.value, list: writable });
          fields.replaceChildren(field(t("Accessory"), accessory), field(t("Control"), kind), field(t("Value"), holder));
          row.readBody = () => ({ ...pick.read(), value: pick.value.read() });
        } else {
          const path = el("select", { "aria-label": t("Page") }, [["/accessories", t("Accessories")], ["/scenes", t("Scenes")], ["/automations", t("Automations")], ["/logbook", t("Logbook")], ["/status", t("Status")]]
            .map(([value, text]) => el("option", { value, text })));
          if (shown.path) { if (![...path.options].some((option) => option.value === shown.path)) path.append(el("option", { value: shown.path, text: shown.path })); path.value = shown.path; }
          fields.replaceChildren(field(t("Page"), path));
          row.readBody = () => ({ path: path.value });
        }
      };
      draw(button);
      type.addEventListener("change", () => draw({ type: type.value }));
      row.read = () => ({ label: label.value.trim(), type: type.value, ...row.readBody() });
      rows.push(row);
      refresh();
    };
    add.addEventListener("click", () => addRow());
    initial.forEach(addRow);
    refresh();
    const node = el("div", { class: "field notify-buttons-field" }, el("span", { class: "field-title", text: t("Buttons") }),
      el("span", { class: "help", text: t("Up to three, each working once within 15 minutes. One on a lock, a door or an alarm opens a page where you confirm it.") }), list, add);
    node.read = () => rows.map((row) => row.read());
    return node;
  }

  /// A number of seconds as an amount and a unit (seconds, minutes, hours).
  function duration(seconds) {
    const unit = el("select", { "aria-label": t("Unit") }, el("option", { value: 1, text: t("seconds") }), el("option", { value: 60, text: t("minutes") }), el("option", { value: 3600, text: t("hours") }));
    const size = seconds % 3600 === 0 ? 3600 : seconds % 60 === 0 ? 60 : 1;
    unit.value = String(size);
    const amount = el("input", { type: "number", min: 1, max: 86400, step: 1, value: seconds / size, "aria-label": t("For") });
    return [amount, unit];
  }

  /// A field per property of a plugin action's input schema: a menu for an enum, a switch for a boolean, a number, else
  /// text. `read()` leaves out what is empty.
  function schemaFields(schema = {}, values = {}) {
    const properties = Object.entries(schema.properties ?? {});
    const required = new Set(schema.required ?? []);
    const readers = [];
    const nodes = properties.map(([key, property]) => {
      let input;
      const value = values[key];
      if (Array.isArray(property.enum)) {
        input = el("select", {}, [...(required.has(key) ? [] : [el("option", { value: "", text: "—" })]), ...property.enum.map((choice) => el("option", { value: JSON.stringify(choice), text: String(choice) }))]);
        input.value = value === undefined ? (required.has(key) ? JSON.stringify(property.enum[0]) : "") : JSON.stringify(value);
        readers.push(() => input.value === "" ? undefined : JSON.parse(input.value));
      } else if (property.type === "boolean") {
        input = el("input", { type: "checkbox", role: "switch", checked: value === true });
        readers.push(() => input.checked);
      } else if (property.type === "number" || property.type === "integer") {
        input = el("input", { type: "number", step: property.type === "integer" ? 1 : "any", min: property.minimum, max: property.maximum, value: value ?? "" });
        readers.push(() => input.value === "" ? undefined : Number(input.value));
      } else {
        input = el("input", { type: "text", value: value ?? "", required: required.has(key), maxLength: property.maxLength });
        readers.push(() => input.value.trim() === "" ? undefined : input.value.trim());
      }
      return home().field(key, input, property.description);
    });
    const read = () => Object.fromEntries(properties.map(([key], index) => [key, readers[index]()]).filter(([, value]) => value !== undefined));
    return { nodes, read };
  }

  /// A notification's buttons (/notify/<id>), behind sign-in: where a tap leads on iOS and Safari and on channels
  /// without buttons, and where a button on a lock, a door or an alarm is confirmed. Each works once, within 15 minutes.
  async function confirmView(main, id) {
    const { statusLine, say } = home();
    let data;
    try { data = await api(`/api/notifications/actions/${encodeURIComponent(id ?? "")}`); }
    catch (e) {
      app().show(main, app().pageHead(t("Notification"), ""), el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("bell")),
        el("p", { class: "muted", text: e.status === 404 ? t("These buttons are gone: a notification's buttons last 15 minutes.") : e.message }),
        el("a", { class: "button", href: "/automations", actionIcon: "workflow", text: t("Automations") })));
      return;
    }
    const line = statusLine();
    const until = new Intl.DateTimeFormat(HomeswiftI18n.locale, { hour: "2-digit", minute: "2-digit" }).format(new Date(data.expires));
    const stateText = { used: t("Already used"), expired: t("Expired") };
    const buttons = data.buttons.map((button) => {
      const node = el("button", { type: "button", class: button.state === "ready" ? "primary" : "", disabled: button.state !== "ready" && button.type !== "open",
        actionIcon: button.type === "open" ? "open" : button.security ? "lock" : button.type === "scene" ? "play" : "check", text: button.label });
      node.addEventListener("click", async () => {
        if (button.type === "open" && button.state !== "ready") { app().navigate(button.path || "/"); return; }
        if (button.security && !(await HomeswiftAdmin.confirmAction({ title: t("{label}?", { label: button.label }), text: t("It changes a lock, a door or an alarm."),
          danger: false, confirmLabel: button.label, confirmIcon: "lock" }))) return;
        await HomeswiftCommon.busyButton(node, async () => {
          const answer = await api(`/api/notifications/actions/${encodeURIComponent(id)}/${button.index}`, { method: "POST", body: { confirmSecurity: button.security } });
          if (button.type === "open") { app().navigate(answer.path || button.path || "/"); return; }
          say(line, t("Done: {label}", { label: button.label }), "ok");
          node.disabled = true;
          node.classList.remove("primary");
        }, { report: (e) => say(line, e.message, "error") });
      });
      return el("div", { class: "notify-choice" }, node, button.state === "ready" ? null : el("span", { class: "muted", text: stateText[button.state] ?? "" }));
    });
    app().show(main, app().pageHead(data.title, data.message),
      el("section", { class: "card notify-confirm" },
        el("p", { class: "muted", text: t("From the automation {name}. Each button works once, until {time}.", { name: data.automation, time: until }) }),
        el("div", { class: "notify-choices" }, buttons), line));
  }

  window.HomeswiftAutomations = { view, draft, confirmView };
})();
