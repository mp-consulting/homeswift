// The settings forms (docs/adr/0002-schema-declares-every-setting.md): one renderer for a plugin's Plugin Settings and
// Plugin Accessory Settings from its config.schema.json, with the schema's conditions, a file field's drop zone and the
// server's rule for which keys hold secrets. The web UI's pages (app.js, settings.js) and plugin pages, which load it
// with settings.js to open an accessory's Settings sheet over themselves (plugin.js's openAccessorySettings), share it.
(() => {
  "use strict";
  const { el, slug } = HomeswiftCommon;
  const { t } = HomeswiftI18n;
  // The web UI's own requests (its sign-in handling) once app.js runs; common.js's on a plugin page.
  const api = (...args) => (window.HomeswiftApp?.api ?? HomeswiftCommon.api)(...args);

  // The server's secret-key rule (Redaction), from the plugin list: set by whoever loaded that list.
  let secretRule = null;
  const readSecretRule = (plugins) => plugins?.secretRule ? {
    keys: new RegExp(plugins.secretRule.keys, "i"), except: new RegExp(plugins.secretRule.except, "i"), placeholder: plugins.secretRule.placeholder,
    reference: new RegExp(plugins.secretRule.reference), signInModes: plugins.secretRule.signInModes || [],
  } : null;
  /// Whether a key holds a secret; with its value, an `auth` that is a sign-in mode ("form", "none") does not.
  const isSecretKey = (key, value) => Boolean(secretRule) && secretRule.keys.test(key) && !secretRule.except.test(key)
    && !(/^auth$/i.test(key) && secretRule.signInModes.includes(value));
  /// Whether a value names a secret kept elsewhere (`vault:<name>`, Redaction.referencePattern).
  const isReference = (value) => Boolean(secretRule) && secretRule.reference.test(value);

  /// A place to drop a file for a path field (a certificate, its key), or to choose it: the bridge keeps the
  /// file next to config.json, owner-only, and the field gets its path.
  function dropZone(key, input, accept = "") {
    const picker = el("input", { type: "file", accept, class: "hidden" });
    const zone = el("div", { class: "drop-zone", role: "button", tabIndex: 0, "aria-label": t("Drop or choose the file for {key}", { key }) },
      t("Drop the file here, or "), el("strong", { text: t("choose it [file]") }), picker);
    const take = async (file) => {
      if (!file) return;
      zone.classList.remove("ok", "error");
      try {
        if (file.size > 256 * 1024) throw new Error(t("That file is too large for a certificate or a key."));
        const { path } = await api("/api/files", { method: "POST", body: { field: key, name: file.name, content: await file.text() } });
        input.value = path;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        zone.classList.add("ok");
        zone.replaceChildren(t("{name} saved", { name: file.name }), picker);
      } catch (e) {
        zone.classList.add("error");
        zone.replaceChildren(e.message, picker);
      }
    };
    zone.addEventListener("click", (event) => { if (event.target !== picker) picker.click(); });
    zone.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); picker.click(); } });
    picker.addEventListener("change", () => take(picker.files[0]));
    zone.addEventListener("dragover", (event) => { event.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (event) => { event.preventDefault(); zone.classList.remove("over"); take(event.dataTransfer.files[0]); });
    return zone;
  }

  /// A schema's `condition` (`{ functionBody: "return model.x === 'y';" }`, or the expression as a string) as a
  /// function of the block and the entry's index, or null when there is none. The page may not run code it
  /// is sent (no eval under its Content-Security-Policy), so this reads the part of JavaScript conditions use:
  /// `model.a.b`, `model.list[arrayIndices].type`, literals and arrays, `.includes()`, `!`, comparisons,
  /// `&&`, `||` and parentheses. A condition it cannot read shows the field.
  function schemaCondition(condition) {
    const source = typeof condition === "string" ? condition : condition && typeof condition.functionBody === "string" ? condition.functionBody : null;
    if (source === null) return null;
    let ast;
    try { ast = parseCondition(source); } catch { return null; }
    return (model, index) => {
      try { return Boolean(evaluateCondition(ast, { model, arrayIndex: index, arrayIndices: index })); } catch { return true; }
    };
  }

  function parseCondition(source) {
    const tokens = [];
    const pattern = /\s*(?:(\d+(?:\.\d+)?)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|([A-Za-z_$][\w$]*)|(===|!==|==|!=|<=|>=|&&|\|\||[!<>()[\].,;]))/y;
    const text = source.trim();
    let match;
    pattern.lastIndex = 0;
    while (pattern.lastIndex < text.length && (match = pattern.exec(text))) {
      if (match[1] !== undefined) tokens.push({ kind: "value", value: Number(match[1]) });
      else if (match[2] !== undefined) tokens.push({ kind: "value", value: match[2].slice(1, -1).replace(/\\(.)/g, "$1") });
      else if (match[3] !== undefined) tokens.push({ kind: "name", value: match[3] });
      else tokens.push({ kind: "op", value: match[4] });
    }
    if (pattern.lastIndex < text.length && text.slice(pattern.lastIndex).trim()) throw new Error("unreadable condition");
    let at = 0;
    const peek = (value) => tokens[at] && tokens[at].kind === "op" && tokens[at].value === value;
    const expect = (value) => { if (!peek(value)) throw new Error(`expected ${value}`); at++; };
    if (tokens[at] && tokens[at].kind === "name" && tokens[at].value === "return") at++;
    const binary = { "||": 1, "&&": 2, "===": 3, "!==": 3, "==": 3, "!=": 3, "<": 4, ">": 4, "<=": 4, ">=": 4 };
    const expression = (minimum = 1) => {
      let left = unary();
      while (tokens[at] && tokens[at].kind === "op" && binary[tokens[at].value] >= minimum) {
        const op = tokens[at++].value;
        left = { op, left, right: expression(binary[op] + 1) };
      }
      return left;
    };
    const unary = () => { if (peek("!")) { at++; return { op: "!", operand: unary() }; } return postfix(primary()); };
    const primary = () => {
      const token = tokens[at++];
      if (!token) throw new Error("unexpected end");
      if (token.kind === "value") return { value: token.value };
      if (token.kind === "name") {
        if (token.value === "true" || token.value === "false") return { value: token.value === "true" };
        if (token.value === "null" || token.value === "undefined") return { value: token.value === "null" ? null : undefined };
        return { name: token.value };
      }
      if (token.value === "(") { const inner = expression(); expect(")"); return inner; }
      if (token.value === "[") {
        const items = [];
        while (!peek("]")) { items.push(expression()); if (peek(",")) at++; else break; }
        expect("]");
        return { array: items };
      }
      throw new Error(`unexpected ${token.value}`);
    };
    const postfix = (node) => {
      for (;;) {
        if (peek(".")) {
          at++;
          const name = tokens[at++];
          if (!name || name.kind !== "name") throw new Error("expected a name");
          if (peek("(")) {
            at++;
            const args = [];
            while (!peek(")")) { args.push(expression()); if (peek(",")) at++; else break; }
            expect(")");
            node = { call: name.value, target: node, args };
          } else node = { member: name.value, target: node };
        } else if (peek("[")) {
          at++;
          const key = expression();
          expect("]");
          node = { index: key, target: node };
        } else return node;
      }
    };
    const ast = expression();
    if (peek(";")) at++;
    if (at < tokens.length) throw new Error("unexpected input");
    return ast;
  }

  function evaluateCondition(node, scope) {
    if ("value" in node) return node.value;
    if (node.name !== undefined) { if (!(node.name in scope)) throw new Error(`unknown ${node.name}`); return scope[node.name]; }
    if (node.array) return node.array.map((item) => evaluateCondition(item, scope));
    const property = (target, key) => (target === null || target === undefined ? undefined : Object.prototype.hasOwnProperty.call(Object(target), key) || Array.isArray(target) && key === "length" ? target[key] : undefined);
    if (node.member !== undefined) return property(evaluateCondition(node.target, scope), node.member);
    if (node.index) return property(evaluateCondition(node.target, scope), evaluateCondition(node.index, scope));
    if (node.call !== undefined) {
      const target = evaluateCondition(node.target, scope);
      const args = node.args.map((arg) => evaluateCondition(arg, scope));
      if (node.call === "includes" && (Array.isArray(target) || typeof target === "string")) return target.includes(args[0]);
      if (node.call === "indexOf" && (Array.isArray(target) || typeof target === "string")) return target.indexOf(args[0]);
      throw new Error(`unknown call ${node.call}`);
    }
    if (node.op === "!") return !evaluateCondition(node.operand, scope);
    const left = evaluateCondition(node.left, scope);
    if (node.op === "&&") return left && evaluateCondition(node.right, scope);
    if (node.op === "||") return left || evaluateCondition(node.right, scope);
    const right = evaluateCondition(node.right, scope);
    switch (node.op) {
      case "===": return left === right;
      case "!==": return left !== right;
      case "==": return left == right; // eslint-disable-line eqeqeq
      case "!=": return left != right; // eslint-disable-line eqeqeq
      case "<": return left < right;
      case ">": return left > right;
      case "<=": return left <= right;
      case ">=": return left >= right;
    }
    throw new Error(`unknown operator ${node.op}`);
  }

  /// An English plural title's singular, for a list's Add button: proxies → proxy, addresses → address, hosts → host (status stays).
  const singular = (text) => text.replace(/ies$/, "y").replace(/(ss|x|ch|sh)es$/, "$1").replace(/([^su])s$/, "$1");

  /// A form from a Homebridge-style config.schema.json; key order follows the schema (and its layout). Its words come
  /// from the schema's own `i18n` (`{ "fr": { "English": "Français" }, … }`), English where it has none. One renderer
  /// for Plugin Settings and Plugin Accessory Settings: `defaults`, by top-level key, is the value a field takes while
  /// it has none of its own (an accessory's plugin-wide default, `get_settings`' `default.value`), shown as
  /// "Default (X)" and given back by clearing it; `onCommit(key, value, state)`, when given, is told of each top-level
  /// field as it is committed (a switch flipped, a text left or Enter), `value` undefined once cleared, with `state`, a
  /// quiet line beside the field's title for its saved or error state.
  function buildForm(root, value, { defaults = null, onCommit = null } = {}) {
    const words = (root.i18n && root.i18n[HomeswiftI18n.language]) || {};
    const tr = (text) => (typeof text === "string" && text && words[text]) || text;
    /// A choice's title: the schema's words, or for one the plugin gives from the home (`x-catalog`) its title as it is (an
    /// accessory's name) and its detail in the web UI's catalogs' words (what it reads, a state).
    const choiceTitle = (o) => o["x-catalog"] ? [o.title, o["x-detail"] && t(o["x-detail"])].filter(Boolean).join(" · ") : tr(o.title) ?? String(o.enum[0]);
    const schema = root.schema || root;
    const properties = schema.properties || {};
    const requiredTop = new Set(Array.isArray(schema.required) ? schema.required : []);
    const fields = new Map();
    const container = el("div", {});
    // Fields and layout groups shown only when their condition holds, re-checked as the form changes.
    const conditional = [];
    // `require`: the condition makes the field required (`x-schema-form.requiredWhen`) rather than shows it.
    const watch = (element, condition, index, require = false) => {
      const test = schemaCondition(condition);
      if (test && element) conditional.push({ element, test, index, require });
    };

    const field = (key, property, current, required, index, fallback) => {
      const made = makeField(key, property, current, required, index, fallback);
      // Shown, not changed (`readOnly`: a Helper's kind, set when it was added).
      if (property.readOnly) for (const control of made.element.querySelectorAll("input, select, textarea, button")) control.disabled = true;
      watch(made.element, property.condition ?? property["x-schema-form"]?.condition, index);
      // Required only while a condition holds (`x-schema-form.requiredWhen`, read as `condition`s are): a block whose
      // settings depend on another (an account or keys, by the route chosen) marks the ones it needs now.
      if (!required) watch(made.element, property["x-schema-form"]?.requiredWhen, index, true);
      return made;
    };
    /// A cron expression (`x-schema-form.type: "schedule"`, the scheduled restart) as a time and the days it runs on,
    /// which it writes as `M H * * d,d`; an expression that says more than that stays as it is, under Custom.
    const scheduleField = (wrap, current) => {
      // The week from Sunday (1 January 2023 was one), in the page's language.
      const weekday = HomeswiftI18n.dateTimeFormat({ weekday: "short", timeZone: "UTC" });
      const names = [0, 1, 2, 3, 4, 5, 6].map((day) => weekday.format(new Date(Date.UTC(2023, 0, 1 + day))));
      const text = typeof current === "string" ? current.trim() : "";
      const simple = /^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+(\*|[0-7](?:,[0-7])*)$/.exec(text);
      const fits = simple && Number(simple[1]) < 60 && Number(simple[2]) < 24;
      const mode = el("select", { "aria-label": t("Repeat") },
        el("option", { value: "never", text: t("Never") }), el("option", { value: "time", text: t("At a time") }), el("option", { value: "custom", text: t("Custom (cron)") }));
      mode.value = !text ? "never" : fits ? "time" : "custom";
      const pad = (n) => String(n).padStart(2, "0");
      const time = el("input", { type: "time", value: fits ? `${pad(simple[2])}:${pad(simple[1])}` : "04:00", "aria-label": t("Time"), title: HomeswiftCommon.homeTimeTitle() });
      const chosen = new Set(fits && simple[3] !== "*" ? simple[3].split(",").map((day) => Number(day) % 7) : []);
      const days = el("span", { class: "days", role: "group", "aria-label": t("Days (none: every day)") }, names.map((name, day) => {
        const box = el("input", { type: "checkbox", checked: chosen.has(day), "aria-label": name });
        box.addEventListener("change", () => { if (box.checked) chosen.add(day); else chosen.delete(day); });
        return el("label", { class: "day" }, box, el("span", { text: name.slice(0, 2) }));
      }));
      const custom = el("input", { type: "text", value: text, placeholder: "0 4 * * 1", "aria-label": t("Cron expression") });
      const timed = el("span", { class: "group-inline" }, time, days);
      const fromTime = () => {
        const [hour, minute] = (time.value || "04:00").split(":").map(Number);
        const list = chosen.size === 0 || chosen.size === 7 ? "*" : [...chosen].sort((a, b) => a - b).join(",");
        return `${minute} ${hour} * * ${list}`;
      };
      const show = () => {
        timed.classList.toggle("hidden", mode.value !== "time");
        custom.classList.toggle("hidden", mode.value !== "custom");
      };
      mode.addEventListener("change", () => {
        // Custom starts from what the time and days say.
        if (mode.value === "custom" && !custom.value.trim()) custom.value = fromTime();
        show();
      });
      show();
      return {
        element: wrap(el("span", { class: "group-inline" }, mode, timed, custom)),
        get: () => (mode.value === "never" ? undefined : mode.value === "time" ? fromTime() : custom.value.trim() || undefined),
      };
    };
    const makeField = (key, property, current, required, index, fallback) => {
      const title = tr(property.title) || key;
      // A default from elsewhere (`defaults`): what the field shows while it is empty, in words.
      const inherits = fallback !== undefined;
      const defaultText = (shown) => shown === undefined || shown === null || shown === "" ? t("Default") : t("Default ({value})", { value: String(shown) });
      const help = property.description ? el("div", { class: "help", text: tr(property.description) }) : null;
      const marked = required || property["x-schema-form"]?.requiredWhen !== undefined;
      const wrap = (control) => el("label", { class: "field" }, el("span", { class: "field-title" }, title, marked ? el("span", { class: `muted required-mark${required ? "" : " hidden"}`, text: ` · ${t("required")}` }) : null), control, help);
      const type = property.type;
      if (property["x-schema-form"]?.type === "schedule") return scheduleField(wrap, current);
      const options = choicesOf(property, choiceTitle);
      // A value config.json has that is not among the choices stays one, so a save does not drop it.
      if (options && current !== undefined && !options.some((o) => same(o.value, current))) options.unshift({ value: current, title: String(current) });
      const named = (value) => options?.find((o) => same(o.value, value))?.title ?? value;
      if (options && options.length > manyChoices) {
        const none = inherits ? defaultText(named(fallback ?? property.default)) : "—";
        const picker = searchSelect(options, current ?? (inherits ? undefined : property.default), none);
        // A button is no label's control: the field is a group named by its title.
        const element = el("div", { class: "field" }, el("span", { class: "field-title" }, title), picker.button, help);
        picker.button.setAttribute("aria-label", typeof title === "string" ? title : property.title ?? key);
        return { element, get: picker.get };
      }
      if (options) {
        const option = (o) => el("option", { value: JSON.stringify(o.value), text: o.title, selected: current !== undefined ? same(o.value, current) : !inherits && same(o.value, property.default) });
        const select = el("select", {}, el("option", { value: "", text: inherits ? defaultText(named(fallback ?? property.default)) : "—" }), ...options.map(option));
        return { element: wrap(select), get: () => (select.value === "" ? undefined : JSON.parse(select.value)) };
      }
      if (type === "boolean" && inherits) {
        // A switch cannot say "as the plugin-wide default": a choice of the default, on or off.
        const shown = fallback ?? property.default;
        const select = el("select", {},
          el("option", { value: "", text: defaultText(shown === undefined || shown === null ? null : shown ? t("On [setting]") : t("Off [setting]")) }),
          el("option", { value: "true", text: t("On [setting]"), selected: current === true }), el("option", { value: "false", text: t("Off [setting]"), selected: current === false }));
        return { element: wrap(select), get: () => (select.value === "" ? undefined : select.value === "true") };
      }
      if (type === "boolean") {
        // `x-schema-form.invert`: the switch shows the opposite of the value, for a key that turns something off
        // (scheduledBackupDisable) under a title that turns it on.
        const invert = property["x-schema-form"]?.invert === true;
        const value = current !== undefined ? current === true : property.default === true;
        const input = el("input", { type: "checkbox", checked: invert ? !value : value });
        const present = current !== undefined;
        return { element: el("label", { class: "toggle" }, el("span", { class: "switch" }, input, el("span")), el("span", {}, el("span", { class: "field-title", text: title }), help)), get: () => {
          const next = invert ? !input.checked : input.checked;
          return next || present ? next : undefined;
        } };
      }
      if ((type === "integer" || type === "number") && property["x-schema-form"]?.type === "slider" && window.HomeswiftWidgets?.level) {
        // A brightness or a colour temperature as the widgets' slider (`x-schema-form`: `type: "slider"`, `track`
        // "white" or "brightness", `unit`, and `min`/`max` when the slider spans less than the schema allows). Unset,
        // it rests on the default, dimmed, and says so; Use the default clears a value.
        const look = property["x-schema-form"];
        const min = look.min ?? property.minimum ?? 0, max = look.max ?? property.maximum ?? 100;
        const step = look.step ?? property.multipleOf ?? 1;
        const format = (v) => (look.unit ? `${v} ${look.unit}` : String(v));
        const shown = fallback ?? property.default;
        let chosen = typeof current === "number" ? current : undefined;
        const slider = HomeswiftWidgets.level({ label: title, showLabel: false, min, max, step, format,
          gradient: look.track === "white" ? HomeswiftWidgets.whiteTrack(min, max) : undefined,
          fill: look.track === "brightness" ? HomeswiftWidgets.brightnessFill() : undefined }, (v) => { chosen = v; paint(); changed(); });
        const reset = el("button", { type: "button", class: "link", text: t("Use the default"), onclick: () => { chosen = undefined; paint(); changed(); slider.node.focus(); } });
        const element = el("div", { class: "field slider-field" }, el("span", { class: "field-title", text: title }), slider.node, help, reset);
        const changed = () => announce(element);
        function paint() {
          const unset = chosen === undefined;
          slider.set(unset ? (typeof shown === "number" ? shown : min) : chosen);
          slider.node.classList.toggle("unset", unset);
          if (unset) {
            const words = defaultText(typeof shown === "number" ? format(shown) : null);
            slider.node.querySelector(".level-text").textContent = words;
            slider.node.setAttribute("aria-valuetext", words);
          }
          reset.hidden = unset;
        }
        paint();
        return { element, get: () => chosen };
      }
      if (type === "integer" || type === "number") {
        const input = el("input", { type: "number", value: current ?? "", placeholder: inherits ? defaultText(fallback ?? property.default) : tr(property.placeholder ?? property["x-schema-form"]?.placeholder) ?? property.default ?? "", min: property.minimum, max: property.maximum, step: property.step ?? (type === "integer" ? 1 : "any"), required });
        return { element: wrap(input), get: () => (input.value === "" ? undefined : Number(input.value)) };
      }
      if (type === "object" && !property.properties) {
        // A map (`additionalProperties`, such as a light's parts by id): a row per entry, its key and its value as the
        // map's values are declared (text when they are not).
        const values = property.additionalProperties && typeof property.additionalProperties === "object" ? property.additionalProperties : { type: "string" };
        const list = el("div", { class: "map-rows" });
        const rows = [];
        const changed = () => announce(list);
        const addRow = (entryKey = "", entryValue = undefined) => {
          const name = el("input", { type: "text", value: entryKey, placeholder: t("Key"), "aria-label": t("Key"), autocomplete: "off", spellcheck: false });
          // The value without a title of its own: the row is the entry, the key beside it says which.
          const f = field("", { ...values, title: undefined, description: undefined }, entryValue, false);
          f.element.querySelector("input, select")?.setAttribute("aria-label", t("Value"));
          const entry = { get: () => [name.value.trim(), f.get()] };
          const row = el("div", { class: "map-row" });
          const remove = el("button", { type: "button", actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); changed(); } });
          row.append(name, f.element, remove);
          rows.push(entry);
          list.append(row);
          return name;
        };
        const entries = current && typeof current === "object" && !Array.isArray(current) ? Object.entries(current) : [];
        for (const [entryKey, entryValue] of entries) addRow(entryKey, entryValue);
        const element = el("fieldset", { class: "map-field" }, el("legend", { text: title }), help, list,
          el("button", { type: "button", actionIcon: "plus", text: t("Add"), onclick: () => addRow().focus() }));
        // Own keys only, whatever they are called (Object.fromEntries defines each, `__proto__` included).
        return { element, get: () => {
          const kept = rows.map((row) => row.get()).filter(([entryKey, entryValue]) => entryKey && entryValue !== undefined);
          return kept.length ? Object.fromEntries(kept) : undefined;
        } };
      }
      if (type === "object" && property.properties) {
        // In a list's entry the section below is closed already: its fields show whole, not behind More options again.
        const nested = buildObject(property, current || {}, index, { split: index === undefined });
        const get = () => { const v = nested.getValue(); return Object.keys(v).length ? v : undefined; };
        if (index === undefined) return { element: el("fieldset", {}, el("legend", { text: title }), help, nested.element), get };
        // In a list's entry (a Dummy accessory's schedule, its auto-reset), a closed section that says what it holds:
        // an entry of a dozen of them open would run for pages.
        const count = el("span", { class: "group-count" });
        const element = el("details", { class: "group-box object-box", "data-icon": property["x-icon"] ?? sectionIcon(key) },
          el("summary", {}, el("span", { text: title }), count), help, nested.element);
        // The settings its conditions show (a timeout's time, not a cron's expression), and how many have a value of
        // their own; the panel's tab reads `data-set`. Recounted while its entry's panel is open (openEntry).
        element.recount = () => {
          const shown = [...nested.parts].filter(([, part]) => !part.element.classList.contains("hidden"));
          const set = shown.filter(([name, part]) => ownValue(part.get(), property.properties[name]?.default)).length;
          count.textContent = settingsLabel(shown.length, set);
          element.dataset.set = String(set);
        };
        element.recount();
        return { element, get };
      }
      if (type === "array") {
        const items = property.items || { type: "string" };
        // A list of choices (`items` an `enum`, or a `oneOf` of them) is a set of checkboxes, written in the choices'
        // order, unless `uniqueItems: false` lets a choice come twice; a value config.json has that is not a choice
        // stays, ticked.
        const choices = choicesOf(items, choiceTitle);
        if (choices && property.uniqueItems !== false) {
          const chosen = Array.isArray(current) ? current : [];
          for (const value of chosen) if (!choices.some((choice) => same(choice.value, value))) choices.push({ value, title: String(value) });
          if (choices.length > manyChoices) {
            const picker = searchSet(choices, chosen.filter((value) => choices.some((choice) => same(choice.value, value))));
            return { element: el("fieldset", { class: "choice-set many" }, el("legend", { text: title }), help, picker.node), get: () => {
              const v = picker.get();
              return v.length || current !== undefined ? v : undefined;
            } };
          }
          const boxes = choices.map((choice) => ({ choice, input: el("input", { type: "checkbox", checked: chosen.some((value) => same(value, choice.value)) }) }));
          const element = el("fieldset", { class: "choice-set" }, el("legend", { text: title }), help,
            boxes.length === 0 ? el("p", { class: "muted choice-empty", text: t("Nothing to choose from yet.") })
              : el("div", { class: "choices" }, boxes.map(({ choice, input }) => el("label", { class: "check" }, input, el("span", { text: choice.title })))));
          return { element, get: () => {
            const v = boxes.filter(({ input }) => input.checked).map(({ choice }) => choice.value);
            return v.length || current !== undefined ? v : undefined;
          } };
        }
        // What one entry is called, for its Add button and an unnamed row: the items' own title, else in English the
        // list's title made singular.
        const noun = items.title ? tr(items.title) : HomeswiftI18n.language === "en" ? singular(title) : null;
        // Its Add button says it as a sentence does: "Address" in lower case, a name in capitals (ECU, UniFi, TV) kept.
        const inSentence = (text) => text.replace(/(?<![\p{L}\p{N}])\p{Lu}\p{Ll}*(?![\p{L}\p{N}])/gu, (word) => word.toLowerCase());
        // A row's name: the key `x-rowTitle` names (or the first of a list of them that has a value), else the usual ones.
        const titleKeys = [...[items["x-rowTitle"] ?? []].flat(), "name", "displayName", "customName", "title", "label", "id", "host", "address", "ip"];
        const rowTitle = (value) => titleKeys.map((key) => value[key]).find((text) => (typeof text === "string" && text.trim()) || typeof text === "number");
        const list = el("div", {});
        const rows = [];
        // A move or a removal is a change as an edit is: the settings sheet saves on `change`.
        const changed = () => announce(list);
        /// The rows in their order again, after a move: each Move button turned off at its end, an unnamed row renumbered.
        const ordered = () => rows.forEach((row, index) => row.placed?.(index));
        const move = (entry, by) => {
          const from = rows.indexOf(entry), to = from + by;
          if (to < 0 || to >= rows.length) return;
          rows.splice(from, 1);
          rows.splice(to, 0, entry);
          list.insertBefore(entry.node, by < 0 ? rows[to + 1].node : rows[to - 1].node.nextSibling);
          ordered();
          changed();
        };
        const addRow = (itemValue) => {
          const entry = {};
          if (items.type === "object" && items.properties) {
            // An entry (a light, a TV) is a row with its name and address; it opens to edit in a side panel, a new one
            // at once. Its fields are whole there (no More options): the panel has the room, and its sections are tabs.
            const nested = buildObject(items, itemValue || {}, () => rows.indexOf(entry), { split: false });
            const name = el("span", { class: "entry-name" });
            const detail = el("span", { class: "entry-detail" });
            const describe = () => {
              const value = nested.getValue();
              name.textContent = rowTitle(value) ?? `${noun ?? title} ${rows.indexOf(entry) + 1}`;
              detail.textContent = [value.ip || value.host, value.mac].filter((text) => text && text !== name.textContent).join(" · ");
              up.setAttribute("aria-label", t("Move {name} up", { name: name.textContent }));
              down.setAttribute("aria-label", t("Move {name} down", { name: name.textContent }));
            };
            // Up and down: the order of a list counts (a TV's sources as its input menu shows them). A click on them
            // does not open or close the row.
            const mover = (glyph, by, tip) => {
              const button = el("button", { type: "button", class: "icon-button entry-move", title: tip }, HomeswiftCommon.icon(glyph));
              button.addEventListener("click", (event) => { event.preventDefault(); move(entry, by); button.focus(); });
              return button;
            };
            const up = mover("up", -1, t("Move up"));
            const down = mover("down", 1, t("Move down"));
            const summary = el("summary", {}, name, detail, up, down, el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: (event) => {
              event.preventDefault();
              row.remove();
              rows.splice(rows.indexOf(entry), 1);
              ordered();
              changed();
            } }));
            // The row never opens in place: a click on it (or Enter, Space) opens the panel.
            const row = el("details", { class: "entry entry-paneled" }, summary, nested.element);
            summary.addEventListener("click", (event) => {
              if (event.target.closest("button")) return;
              event.preventDefault();
              openEntry(nested, () => name.textContent, summary);
            });
            nested.element.addEventListener("input", describe);
            entry.get = nested.getValue;
            entry.node = row;
            entry.placed = (index) => {
              up.disabled = index === 0;
              down.disabled = index === rows.length - 1;
              describe();
            };
            rows.push(entry);
            list.append(row);
            // Only the row before it changes (its Move down turns on): not every row again for each one a list opens with.
            rows.at(-2)?.placed?.(rows.length - 2);
            // One the person adds opens to be filled in (the ones the list opens with were there already).
            if (itemValue === undefined) queueMicrotask(() => openEntry(nested, () => name.textContent, summary));
            entry.placed(rows.length - 1);
            return;
          }
          const row = el("div", { class: "item" });
          const remove = el("button", { actionIcon: "trash", class: "link danger", text: t("Remove"), onclick: () => { row.remove(); rows.splice(rows.indexOf(entry), 1); changed(); } });
          {
            const f = field("", items, itemValue, false);
            row.append(el("div", { class: "item-head" }, f.element, remove));
            entry.get = f.get;
          }
          rows.push(entry);
          list.append(row);
        };
        for (const item of Array.isArray(current) ? current : []) addRow(item);
        const element = el("fieldset", {}, el("legend", { text: title }), help, list,
          el("button", { actionIcon: "plus", text: noun ? t("Add {item}", { item: inSentence(noun) }) : t("Add"), onclick: () => addRow(undefined) }));
        return { element, get: () => { const v = rows.map((r) => r.get()).filter((x) => x !== undefined); return v.length ? v : undefined; } };
      }
      if (type === "string" && property["x-schema-form"]?.type === "menu" && property["x-schema-form"].source) {
        // A pop-up menu of choices the bridge lists when it opens, from the form as it stands (the Assistant's Model:
        // the models of the provider chosen above, with its key): Default (X), the choices, and Other… to type one.
        // `by` and `defaults`: the field whose value picks the default shown (the provider), and each one's.
        const { source, by, defaults: perChoice } = property["x-schema-form"];
        let chosen = typeof current === "string" && current ? current : undefined;
        let fallbackName = typeof property.placeholder === "string" ? property.placeholder : null;
        const followDefault = () => { if (by && perChoice && typeof perChoice === "object") fallbackName = perChoice[getValue()[by]] ?? fallbackName; };
        const button = el("button", { type: "button", class: "select-button", "aria-haspopup": "menu" });
        const element = el("div", { class: "field" }, el("span", { class: "field-title" }, title), button, help);
        const paint = () => {
          button.textContent = chosen ?? defaultText(fallbackName);
          button.classList.toggle("placeholder", !chosen);
        };
        const choose = (value) => {
          chosen = value || undefined;
          paint();
          element.dispatchEvent(new Event("input", { bubbles: true }));
          element.dispatchEvent(new Event("change", { bubbles: true }));
        };
        button.addEventListener("click", async (event) => {
          const keyboard = event.detail === 0;
          if (button.getAttribute("aria-busy") === "true") return;
          button.setAttribute("aria-busy", "true");
          let answer;
          try { answer = await api(source, { method: "POST", body: { block: getValue() } }); } catch (e) { answer = { models: [], error: e.message }; }
          button.removeAttribute("aria-busy");
          if (typeof answer.default === "string") { fallbackName = answer.default; paint(); }
          const listed = Array.isArray(answer.models) ? answer.models : [];
          const ids = listed.map((one) => one.id);
          HomeswiftCommon.menu(button, [
            { label: defaultText(fallbackName), checked: !chosen, onSelect: () => choose(undefined) },
            answer.error ? { heading: t("The list could not be read"), detail: answer.error } : null,
            listed.length || (chosen && !ids.includes(chosen)) ? { separator: true } : null,
            // One typed before, or no longer listed, stays a choice.
            chosen && !ids.includes(chosen) ? { label: chosen, checked: true, onSelect: () => {} } : null,
            ...listed.map((one) => ({ label: one.name || one.id, checked: one.id === chosen, onSelect: () => choose(one.id) })),
            { separator: true },
            { label: t("Other…"), icon: "edit", pinned: true, onSelect: async () => {
              const text = await HomeswiftCommon.promptDialog(tr(property.description) ?? title, chosen ?? "");
              if (text !== null) choose(text.trim());
              button.focus();
            } },
          ], { keyboard, search: listed.length > 8 ? t("Search") : null });
        });
        container.addEventListener("change", () => { followDefault(); paint(); });
        queueMicrotask(() => { followDefault(); paint(); });
        paint();
        return { element, get: () => chosen };
      }
      const input = el("input", { type: property["x-schema-form"] && property["x-schema-form"].type === "password" ? "password" : "text", value: current ?? "", placeholder: inherits ? defaultText(fallback ?? property.default) : tr(property.placeholder ?? property["x-schema-form"]?.placeholder) ?? property.default ?? "", required });
      if (property["x-schema-form"]?.type === "file") return { element: el("div", {}, wrap(input), dropZone(key, input, property["x-schema-form"].accept)), get: () => (input.value === "" ? undefined : input.value) };
      // A secret's key (the rule references resolve by): a value typed, or an entry of the vault.
      if (isSecretKey(key)) return secretField(wrap, input);
      return { element: wrap(input), get: () => (input.value === "" ? undefined : input.value) };
    };
    /// A secret's field with the vault's menu beside it: an entry picked is written `vault:<name>` and shown as it is,
    /// a name rather than the secret; a typed value stays masked when the schema masks it.
    const secretField = (wrap, input) => {
      const masked = input.type === "password";
      const reveal = () => { input.type = masked && !isReference(input.value) ? "password" : "text"; };
      const pick = el("button", { type: "button", class: "icon-button", "aria-label": t("Choose from the vault"), title: t("Choose from the vault") }, HomeswiftCommon.icon("vault"));
      pick.addEventListener("click", async (event) => {
        event.preventDefault();
        const keyboard = event.detail === 0;
        let entries = [];
        try { entries = (await api("/api/vault")).entries; } catch { /* the menu still opens the vault */ }
        const choose = (value) => { input.value = value; reveal(); input.dispatchEvent(new Event("input", { bubbles: true })); };
        HomeswiftCommon.menu(pick, [
          // The entry the field names now is ticked.
          ...entries.map((entry) => ({ label: entry.name, icon: "key", checked: input.value === `vault:${entry.name}`, onSelect: () => choose(`vault:${entry.name}`) })),
          isReference(input.value) ? { label: t("Type a value instead"), icon: "edit", pinned: true, onSelect: () => { choose(""); input.focus(); } } : null,
          { label: entries.length ? t("Open the vault") : t("Add one in the vault"), icon: "gear", pinned: true, href: "/settings/vault" },
        ].filter(Boolean), { keyboard, search: entries.length ? t("Search the vault") : null });
      });
      input.addEventListener("input", reveal);
      reveal();
      return { element: wrap(el("span", { class: "secret-field" }, input, pick)), get: () => (input.value === "" ? undefined : input.value) };
    };

    /// Required fields and the ones that hold a value show; the rest wait under "More options", unless that would
    /// hide them all (a box of empty settings, a budget, shows its fields rather than a closed box in a box).
    const isSet = (value) => value !== undefined && value !== null && value !== "" && !(Array.isArray(value) && !value.length);
    /// Set: a value of its own other than the default the schema declares (a switch left on as it comes is not).
    const ownValue = (value, schemaDefault) => isSet(value) && JSON.stringify(value) !== JSON.stringify(schemaDefault);
    /// A group's or a section's count: its number of settings, and how many are set.
    const settingsLabel = (total, set) => set
      ? (total === 1 ? t("1 setting · {set} set", { set }) : t("{count} settings · {set} set", { count: total, set }))
      : total === 1 ? t("1 setting") : t("{count} settings", { count: total });
    function splitFields(entries) {
      const shown = [], more = [];
      for (const { element, required, value } of entries) (required || isSet(value) ? shown : more).push(element);
      if (!more.length || !shown.length) return [...shown, ...more];
      return [...shown, el("details", { class: "more-options" }, el("summary", { text: t("More options ({count})", { count: more.length }) }), el("div", { class: "fields" }, more))];
    }

    /// A list's entry in a side panel (common.js's openSheet): its fields under General, each section of settings (a
    /// schedule, a notification) a tab of its own, which says when it holds a value. The fields move into the panel and
    /// back into the row as it closes; the panel sits in the form, so what is typed there reaches it as from the row.
    const sectionIcon = (key) => [[/schedule|cron|time/i, "calendar"], [/reset|restore/i, "restore"], [/notif|alert/i, "bell"],
      [/sensor/i, "sensor"], [/limit/i, "clock"], [/condition|rule|trigger/i, "workflow"], [/simulat|motion/i, "blind"],
      [/fade|dim|light/i, "bulb"], [/auth|account|login|token/i, "key"], [/network|address|host/i, "globe"]].find(([pattern]) => pattern.test(key))?.[1] ?? "sliders";
    let panels = 0;
    function openEntry(nested, title, trigger) {
      const body = nested.element;
      const home = body.parentElement;
      const sections = [...body.querySelectorAll(":scope > .fields > .object-box")];
      const id = `entry-panel-${++panels}`;
      const tabs = el("div", { class: "plugins-tabs entry-tabs", role: "tablist", "aria-label": t("Sections") });
      const pages = [{ label: t("General"), icon: "gear", section: null }, ...sections.map((section) => ({
        label: section.querySelector(":scope > summary > span").textContent, icon: section.dataset.icon || "sliders", section }))];
      let current = 0;
      const show = (index) => {
        current = index;
        body.dataset.page = index ? "section" : "general";
        sections.forEach((section) => { section.open = true; section.classList.toggle("entry-page", section === pages[index].section); });
        [...tabs.children].forEach((tab, at) => { tab.setAttribute("aria-selected", String(at === index)); tab.tabIndex = at === index ? 0 : -1; });
        // The tabs scroll sideways on a phone: the chosen one comes into sight.
        tabs.children[index]?.scrollIntoView({ block: "nearest", inline: "nearest" });
        body.scrollTop = 0;
      };
      // A section its conditions hide (a lamp's fade without Dimmer) leaves the tabs; one with a value is marked. Run
      // after the form has applied its conditions (its listeners come first).
      const sync = () => {
        pages.forEach(({ section }, index) => {
          if (!section) return;
          const tab = tabs.children[index];
          section.recount();
          tab.hidden = section.classList.contains("hidden");
          tab.classList.toggle("has-value", section.dataset.set !== "0");
          tab.title = section.querySelector(".group-count").textContent;
        });
        if (tabs.children[current]?.hidden) show(0);
      };
      pages.forEach((page, index) => tabs.append(el("button", { type: "button", role: "tab", "aria-controls": `${id}-body`, actionIcon: page.icon, text: page.label,
        onclick: () => show(index),
        onkeydown: (event) => {
          const visible = [...tabs.children].filter((tab) => !tab.hidden);
          const at = visible.indexOf(event.currentTarget);
          const next = event.key === "ArrowRight" ? visible[(at + 1) % visible.length] : event.key === "ArrowLeft" ? visible[(at + visible.length - 1) % visible.length]
            : event.key === "Home" ? visible[0] : event.key === "End" ? visible.at(-1) : null;
          if (next) { event.preventDefault(); next.focus(); next.click(); }
        } })));
      container.addEventListener("input", sync);
      container.addEventListener("change", sync);
      const heading = el("h2", { id: `${id}-title`, text: title() });
      body.id = `${id}-body`;
      const dialog = HomeswiftCommon.openSheet((dismiss) => {
        const panel = el("div", { class: "plugins-panel entry-panel" },
          el("div", { class: "plugins-panel-head" }, heading,
            el("button", { type: "button", class: "plugins-close", actionIcon: "close", "aria-label": t("Close"), onclick: () => dismiss() })),
          sections.length ? tabs : null, body,
          el("div", { class: "actions" }, el("button", { type: "button", class: "primary", actionIcon: "check", text: t("Done"), onclick: () => dismiss() })));
        panel.addEventListener("input", () => { heading.textContent = title(); });
        return panel;
      }, `${id}-title`, { returnFocus: trigger, parent: container, onClose: () => {
        container.removeEventListener("input", sync);
        container.removeEventListener("change", sync);
        delete body.dataset.page;
        body.removeAttribute("id");
        sections.forEach((section) => { section.classList.remove("entry-page"); section.open = false; });
        home.append(body);
        if (trigger.isConnected) trigger.focus();
      } });
      dialog.classList.add("entry-sheet");
      show(0);
      sync();
      return dialog;
    }

    function buildObject(objectSchema, current, index, { split: splitting = true } = {}) {
      const props = objectSchema.properties || {};
      const required = new Set(Array.isArray(objectSchema.required) ? objectSchema.required : []);
      const parts = new Map();
      const element = el("div", { class: "entry-body" });
      const entries = [];
      for (const [key, property] of Object.entries(props)) {
        const isRequired = required.has(key) || property.required === true;
        const f = field(key, property, current[key], isRequired, index);
        parts.set(key, f);
        entries.push({ element: f.element, required: isRequired, value: current[key] });
      }
      const split = splitting ? splitFields(entries) : entries.map((entry) => entry.element);
      const first = split.filter((node) => !node.classList?.contains("more-options"));
      element.append(el("div", { class: "fields" }, first), ...split.filter((node) => node.classList?.contains("more-options")));
      return { element, parts, getValue: () => {
        const out = {};
        for (const [key, value] of Object.entries(current)) if (!props[key]) out[key] = value;
        for (const [key, f] of parts) { const v = f.get(); if (v !== undefined) out[key] = v; }
        return out;
      } };
    }

    // What Find a setting looks through: each top-level field with its title, help and key.
    const searchable = [];
    const render = (key) => {
      const property = properties[key];
      if (!property || fields.has(key)) return null;
      const fallback = defaults && key in defaults ? defaults[key] ?? null : undefined;
      const f = field(key, property, value[key], requiredTop.has(key) || property.required === true, undefined, fallback);
      fields.set(key, f);
      searchable.push({ element: f.element, text: [tr(property.title), tr(property.description), key].filter(Boolean).join(" ").toLowerCase() });
      if (onCommit) {
        // Its saved or error state, quiet, after its title.
        const state = el("span", { class: "field-state", role: "status", "aria-live": "polite" });
        (f.element.querySelector(".field-title") ?? f.element).append(state);
        f.element.addEventListener("change", () => onCommit(key, f.get(), state));
      }
      return f.element;
    };
    // A closed group says what it holds: its number of settings, and how many have a value of their own.
    const groupCounts = [];
    /// `keys` gathers the top-level keys the item draws, for its group's count; `depth` is how deep in groups it sits.
    const layoutItem = (item, depth = 0, keys = []) => {
      const drawn = (key) => { const node = render(key); if (node) keys.push(key); return node; };
      if (typeof item === "string") return item === "*" ? Object.keys(properties).map(drawn) : drawn(item);
      if (item && item.key) { const node = drawn(item.key); if (item.condition) watch(node, item.condition); return node; }
      if (item && Array.isArray(item.items)) {
        const own = [];
        let inner = item.items.map((child) => layoutItem(child, depth + 1, own)).flat().filter(Boolean);
        keys.push(...own);
        if (!inner.length) return null;
        // A group holding one object of its own name (Budget in Budget) shows the object's fields, not a box titled
        // again inside it.
        const only = inner.length === 1 && inner[0].tagName === "FIELDSET" ? inner[0] : null;
        if (only && item.title && only.querySelector(":scope > legend")?.textContent === tr(item.title)) inner = [...only.children].filter((child) => child.tagName !== "LEGEND");
        const help = item.description ? el("p", { class: "help group-help", text: tr(item.description) }) : null;
        let node;
        if (depth > 0 && item.title && !item.expandable) {
          // A group in a group is a heading over its fields, not a box in a box.
          // A group of switches only (one per kind of detection), explained by its heading, sits in columns: each one's
          // own words are its tooltip, and still what a screen reader says of it.
          const compact = Boolean(item.description) && inner.every((child) => child.matches?.(".toggle"));
          if (compact) for (const child of inner) {
            const words = child.querySelector(".help");
            if (!words) continue;
            child.title = words.textContent;
            words.classList.add("visually-hidden");
          }
          node = el("div", { class: `form-subgroup${compact ? " compact" : ""}` }, el("h4", { text: tr(item.title) }), help, el("div", { class: "fields" }, ...inner));
        } else if (item.type === "fieldset" || item.title) {
          const count = el("span", { class: "group-count" });
          // Only a group that closes says it; a list or a box alone (a controller's entries, a budget) is no count of settings.
          if (item.expandable && own.some((key) => !["array", "object"].includes(properties[key]?.type))) groupCounts.push({ count, keys: own });
          node = el("details", { class: "group-box", "data-section": item.section || slug(item.title || ""), open: !item.expandable || item.expanded !== false },
            el("summary", {}, item.icon ? HomeswiftCommon.icon(item.icon) : null, el("span", { text: tr(item.title) || t("More") }), count), help, el("div", { class: "fields" }, ...inner));
        } else {
          node = el("div", { class: "fields" }, ...inner);
        }
        watch(node, item.condition);
        return node;
      }
      return null;
    };
    if (Array.isArray(root.layout)) for (const item of root.layout) { const node = layoutItem(item); if (node) container.append(...[node].flat()); }
    const restKeys = Object.keys(properties).filter((key) => !fields.has(key));
    const rest = restKeys.map((key) => ({ key, element: render(key) })).filter((entry) => entry.element)
      // A field with a condition is shown in the main part while its condition holds, not under More options.
      .map(({ key, element }) => ({ element, required: requiredTop.has(key) || properties[key].required === true || Boolean(properties[key].condition ?? properties[key]["x-schema-form"]?.condition ?? properties[key]["x-schema-form"]?.requiredWhen), value: value[key] }));
    if (rest.length) {
      const split = splitFields(rest);
      container.append(el("div", { class: "fields" }, split.filter((node) => !node.classList?.contains("more-options"))),
        ...split.filter((node) => node.classList?.contains("more-options")));
    }

    const getValue = () => {
      const out = {};
      for (const [key, v] of Object.entries(value)) if (!properties[key]) out[key] = v;
      for (const [key, f] of fields) { const v = f.get(); if (v !== undefined) out[key] = v; }
      return out;
    };
    // A hidden field keeps its value, as Homebridge's form does; it only leaves the screen.
    const applyConditions = () => {
      if (!conditional.length) return;
      const model = getValue();
      const holds = ({ test, index }) => test(model, typeof index === "function" ? index() : index);
      for (const entry of conditional) if (!entry.require) entry.element.classList.toggle("hidden", !holds(entry));
      // A field is required while its condition holds and it is on screen (its own and its group's conditions).
      for (const entry of conditional) {
        if (!entry.require) continue;
        const { element } = entry;
        const needed = holds(entry) && !element.closest(".hidden");
        element.querySelector(".required-mark")?.classList.toggle("hidden", !needed);
        const control = element.querySelector("input, select, textarea");
        if (control) control.required = needed;
      }
      // More options counts the ones its conditions show (a garage door's, not a thermostat's), and goes when none is.
      for (const more of container.querySelectorAll("details.more-options")) {
        const shown = more.querySelectorAll(":scope > .fields > :not(.hidden)").length;
        more.querySelector(":scope > summary").textContent = t("More options ({count})", { count: shown });
        more.classList.toggle("hidden", !shown);
      }
    };
    const countGroups = () => {
      if (!groupCounts.length) return;
      const model = getValue();
      for (const { count, keys: all } of groupCounts) {
        // The ones on screen: a field its condition hides (another provider's) is not counted.
        const keys = all.filter((key) => !fields.get(key)?.element.classList.contains("hidden"));
        const set = keys.filter((key) => ownValue(model[key], properties[key]?.default)).length;
        count.textContent = settingsLabel(keys.length, set);
      }
    };
    container.addEventListener("input", applyConditions);
    container.addEventListener("change", applyConditions);
    container.addEventListener("change", countGroups);
    container.addEventListener("click", () => setTimeout(applyConditions, 0));   // rows added or removed
    applyConditions();
    countGroups();
    // Many settings: a search over them, which opens the groups that hold a match and leaves the rest out of sight.
    if (searchable.length < 15) return { element: container, getValue };
    const query = el("input", { type: "search", placeholder: t("Find a setting"), "aria-label": t("Find a setting"), autocomplete: "off", spellcheck: false });
    const none = el("p", { class: "muted form-search-none hidden", role: "status", text: t("No setting matches.") });
    const groups = () => container.querySelectorAll("details.group-box, details.more-options, .form-subgroup");
    let opened = null;
    const filter = () => {
      const words = query.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
      // The groups open as the person left them once the search is cleared.
      if (words.length && !opened) opened = new Map([...container.querySelectorAll("details")].map((node) => [node, node.open]));
      let shown = 0;
      for (const { element, text } of searchable) {
        const miss = words.length > 0 && !words.every((word) => text.includes(word));
        element.classList.toggle("search-miss", miss);
        if (!miss) shown++;
      }
      for (const group of groups()) {
        const any = [...group.querySelectorAll(".field, .toggle, fieldset")].some((node) => !node.closest(".search-miss"));
        group.classList.toggle("search-miss", words.length > 0 && !any);
        if (words.length && group.tagName === "DETAILS") group.open = any;
      }
      if (!words.length && opened) { for (const [node, open] of opened) node.open = open; opened = null; }
      none.classList.toggle("hidden", !words.length || shown > 0);
    };
    // Not a change of the form: its listeners (a save bar, a field's save) never hear it.
    for (const type of ["input", "change"]) query.addEventListener(type, (event) => event.stopPropagation());
    query.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      event.stopPropagation();
    });
    query.addEventListener("input", filter);
    query.classList.add("form-search");
    const element = el("div", { class: "form-with-search" }, query, none, container);
    return { element, getValue };
  }

  /// Beyond this many choices a field shows what is chosen and a searchable menu of the rest, rather than every choice
  /// (a home's hundred lights or scenes in a remote's channel).
  const manyChoices = 10;
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  /// Tells the form a picker's value changed, as a select or a checkbox would: the settings sheet saves on `change`.
  const announce = (node) => { node.dispatchEvent(new Event("input", { bubbles: true })); node.dispatchEvent(new Event("change", { bubbles: true })); };

  /// A field's choices, from a `oneOf` of single `enum`s (titled by `choiceTitle`) or an `enum`; null for none.
  function choicesOf(schema, choiceTitle) {
    if (schema.oneOf && schema.oneOf.every((o) => Array.isArray(o.enum))) return schema.oneOf.map((o) => ({ value: o.enum[0], title: choiceTitle(o) }));
    return Array.isArray(schema.enum) ? schema.enum.map((v) => ({ value: v, title: String(v) })) : null;
  }

  /// One choice among many: a select button whose menu has a search field. `none` is the empty choice's words.
  function searchSelect(options, current, none) {
    let value = current;
    const button = el("button", { type: "button", class: "select-button", "aria-haspopup": "menu" });
    const draw = () => {
      const chosen = options.find((o) => same(o.value, value));
      button.textContent = chosen?.title ?? none;
      button.classList.toggle("placeholder", !chosen);
    };
    button.addEventListener("click", () => HomeswiftCommon.menu(button, [
      { label: none, checked: value === undefined, onSelect: () => { value = undefined; draw(); announce(button); } },
      { separator: true },
      ...options.map((o) => ({ label: o.label ?? o.title, group: o.group, filter: o.filter, checked: same(o.value, value), onSelect: () => { value = o.value; draw(); announce(button); } })),
    ], { search: t("Search") }));
    draw();
    return { button, get: () => value };
  }

  /// Several choices among many: the chosen ones as chips (each with its remove button), and Add, whose menu searches
  /// the others. A choice is `{ value, title }`, with a `label` for the menu when it differs from the chip's title (its
  /// `group` heading it there already), a `group` and a `filter` (menu()'s).
  function searchSet(choices, chosen) {
    let values = chosen.slice();
    const list = el("div", { class: "chips chosen-list" });
    const add = el("button", { type: "button", class: "add-choice", actionIcon: "plus", "aria-haspopup": "menu", text: t("Choose…") });
    const draw = () => {
      list.replaceChildren(...values.map((value) => {
        const choice = choices.find((c) => same(c.value, value));
        const title = choice?.title ?? String(value);
        // A choice's `icon` says its kind on its chip and in the menu (a light, a Scene, an Automation).
        return el("span", { class: choice?.icon ? "chip removable with-icon" : "chip removable" },
          choice?.icon ? el("span", { class: "chip-icon", "aria-hidden": "true" }, HomeswiftCommon.icon(choice.icon)) : null,
          el("span", { class: "chosen-name", text: title, title }),
          el("button", { type: "button", class: "icon-button", "aria-label": t("Remove {name}", { name: title }),
            onclick: () => { values = values.filter((v) => !same(v, value)); draw(); announce(list); add.focus(); } }, HomeswiftCommon.icon("close")));
      }));
      list.hidden = values.length === 0;
    };
    // The menu stays open while choices are ticked (several lights in a row, the search kept); Done on a phone. A
    // choice with `members` (a Group) ticks them all, or none once they all are; `nested` ones are its members.
    const has = (value) => values.some((v) => same(v, value));
    add.addEventListener("click", () => HomeswiftCommon.menu(add, choices.map((c) => {
      const common = { label: c.label ?? c.title, group: c.group, filter: c.filter, search: c.search, nested: c.nested, icon: c.icon, checkbox: true, keepOpen: true };
      if (c.members) {
        const state = () => c.members.every(has) ? true : c.members.some(has) ? "mixed" : false;
        return { ...common, aggregate: true, checked: state, onSelect: () => {
          values = state() === true ? values.filter((v) => !c.members.some((m) => same(m, v))) : [...values, ...c.members.filter((m) => !has(m))];
          draw();
          announce(list);
        } };
      }
      return { ...common, checked: () => has(c.value), onSelect: () => {
        values = has(c.value) ? values.filter((v) => !same(v, c.value)) : [...values, c.value];
        draw();
        announce(list);
      } };
    }), { search: t("Search"), done: t("Done") }));
    draw();
    return { node: el("div", { class: "chosen-set" }, list, add), get: () => values };
  }

  window.HomeswiftForms = {
    buildForm, dropZone, schemaCondition, isSecretKey, isReference, readSecretRule,
    /// A searchable choice among many, and a searchable set of them (the Remotes page's targets and Scenes).
    searchSelect, searchSet,
    secretRule: () => secretRule,
    /// Sets the rule from the plugin list (`/api/plugins`), or clears it with null; answers it.
    setSecretRule: (rule) => { secretRule = rule; return rule; },
    /// Loads the rule once, for a page that has not loaded the plugin list (a plugin page's Settings sheet).
    loadSecretRule: async () => secretRule ?? (secretRule = readSecretRule(await api("/api/plugins").catch(() => null))),
  };
})();
