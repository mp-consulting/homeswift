// Setup (GLOSSARY.md, "Setup"): /setup lists what each plugin finds, with where each device stands, and sets up the
// devices and accounts that ask for a code, a button press, a sign-in or keys, in one sheet whatever the plugin. The
// server holds each Setup in progress (POST /api/setup/…, SetupRoutes.swift); this page only draws its prompts.
// app.js routes /setup here and lends its helpers (HomeswiftApp) when the view is drawn.
(() => {
  "use strict";

  const { el, tile, menuButton } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  const app = () => window.HomeswiftApp;
  const api = (...args) => app().api(...args);
  const post = (path, body) => api(`/api/setup/${path}`, { method: "POST", body });
  const bare = (name) => name.replace(/[\s_-]+/g, "").toLowerCase();

  /// What each Authorization Method is called, and the glyph its rows and the sheet show.
  const methods = {
    none: [() => t("Nothing to set up"), "check"],
    buttonPress: [() => t("Press a button"), "pair"],
    deviceCode: [() => t("Enter a code"), "key"],
    accountLogin: [() => t("Sign in"), "user"],
    browserRedirect: [() => t("Sign in with a browser"), "browser"],
    apiKey: [() => t("Enter keys"), "key"],
  };
  /// What the account's button says, by its Authorization Method.
  const accountActions = {
    buttonPress: [() => t("Pair"), () => t("Pair again"), "pair"],
    deviceCode: [() => t("Pair"), () => t("Pair again"), "pair"],
    accountLogin: [() => t("Sign in"), () => t("Sign in again"), "user"],
    browserRedirect: [() => t("Sign in"), () => t("Sign in again"), "browser"],
    apiKey: [() => t("Enter keys"), () => t("Change keys"), "key"],
  };
  /// A device's status: its words and tone. Set up is the usual state, a quiet dot; the others say so in words.
  const statuses = {
    setUp: [() => t("Set up"), "on"],
    notResponding: [() => t("Not responding"), "away"],
    discovered: [() => t("Ready"), "on"],
    needsAuthorization: [() => t("Needs setup"), "away"],
    excluded: [() => t("Excluded"), "paused"],
  };

  async function view(main) {
    const plugins = await api("/api/plugins");
    const byPlatform = new Map(plugins.plugins.map((plugin) => [plugin.platform, plugin]));
    const blocks = plugins.blocks.filter((block) => !block.system && byPlatform.has(block.platform));
    const wanted = decodeURIComponent(location.hash.slice(1));
    // From a plugin's page (/setup?start#<slug>): its account's Setup opens once the plugin has said where it stands.
    const start = new URLSearchParams(location.search).has("start");
    if (start) history.replaceState(history.state, "", `/setup${location.hash}`);
    const cards = blocks.map((block) => instanceCard(block, byPlatform.get(block.platform),
      { open: blocks.length === 1 || block.slug === wanted, start: start && block.slug === wanted }));
    // The plugins in use, one row each, and a way to add another; before any, the brands to start from.
    const add = el("button", { type: "button", class: "primary", actionIcon: "plus", text: t("Add a plugin"), onclick: (event) => pickPlugin(plugins, event.currentTarget) });
    // Or the Assistant does it: it finds the plugin, starts the Setup and hands the steps with a secret back to the sheet.
    // Always shown: without an Assistant yet, it leads to setting one up (a provider and its key).
    const assistant = el("button", { type: "button", actionIcon: "sparkle", class: "setup-assistant", text: t("Ask the Assistant"), onclick: async () => {
      if (window.HomeswiftChat?.available()) { HomeswiftChat.ask(t("Help me add my accessories: ")); return; }
      if (await HomeswiftCommon.confirmDialog(t("The Assistant is not set up yet: it needs an AI provider and its key. Set it up now?"))) app().navigate("/plugins/add/HomeswiftAiKit");
    } });
    app().show(main,
      cards.length
        ? app().pageHead(t("Add accessories"), t("Open a plugin to set up its devices, or add one for another brand."), assistant, add)
        : app().pageHead(t("Add accessories"), t("Start with the brand of your devices."), assistant),
      cards.length ? el("div", { class: "setup-list" }, ...cards.map((card) => card.node)) : brandGrid(plugins));
    // From a plugin's menu (/setup#<slug>): its card in view, open.
    const card = wanted ? document.getElementById(`setup-${wanted}`) : null;
    const reveal = () => card?.scrollIntoView({ block: "start", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    reveal();
    // A plugin just added: its card says it is the one, for a moment.
    if (card && history.state?.added === wanted) {
      card.classList.add("just-added");
      setTimeout(() => card.classList.remove("just-added"), 2200);
      history.replaceState(null, "", location.href);
    }
    // Every plugin looks at once: a slow cloud does not hold the others back.
    // A card that turns out to need someone moves to the top of the list: the one asked for is followed there.
    await Promise.all(cards.map((one) => one.load().then(() => { if (one.node === card) reveal(); })));
  }

  /// The plugins compiled in that can be added: one with an account opens its Setup at once (the block is saved when it
  /// is done), one without is added as it is and its card looks for devices. Those not in use yet come first.
  const addablePlugins = (plugins) => {
    const used = (plugin) => plugins.blocks.some((block) => block.platform === plugin.platform);
    // System platforms (the Assistant) have no Setup: their settings are elsewhere.
    return plugins.plugins.filter((plugin) => plugin.accountAuthorization)
      .map((plugin) => ({ plugin, used: used(plugin) }))
      .sort((a, b) => Number(a.used) - Number(b.used) || a.plugin.name.localeCompare(b.plugin.name));
  };

  async function addPlugin(plugins, plugin, trigger) {
    const block = { platform: plugin.platform, name: app().uniqueName(plugin.name, plugins.blocks) };
    // Drawn again with the new plugin's card in view, open.
    const redraw = () => {
      const slug = HomeswiftCommon.slug(block.name);
      history.replaceState({ added: slug }, "", `/setup#${encodeURIComponent(slug)}`);
      app().route();
    };
    if (plugin.accountAuthorization !== "none") { open({ block, plugin, draft: true, firstTime: true, trigger, after: redraw }); return; }
    try {
      await api(`/api/config/block/${encodeURIComponent(block.platform)}/${encodeURIComponent(block.name)}`, { method: "POST", body: {} });
      redraw();
    } catch (e) { HomeswiftCommon.showAlert(e.message); }
  }

  /// How a plugin connects, in a few words: a sign-in, a button on a hub, nothing.
  const howItConnects = (plugin) => plugin.accountAuthorization === "none" ? t("Nothing to sign in to") : methods[plugin.accountAuthorization][0]();

  /// A search over a list of plugins: hides those that do not match every word, and says when none does.
  function searchOver(items, text) {
    const none = el("p", { class: "muted setup-none", hidden: true, text: t("No plugin matches.") });
    const search = el("input", { type: "search", class: "search setup-search", placeholder: t("Search plugins"), "aria-label": t("Search plugins"),
      oninput: () => {
        const words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
        let shown = 0;
        for (const [index, item] of items.entries()) shown += (item.hidden = !words.every((word) => text[index].includes(word))) ? 0 : 1;
        none.hidden = shown > 0;
      } });
    return { search, none };
  }
  const searchText = (plugin) => `${plugin.name} ${t(plugin.summary ?? "")} ${plugin.summary ?? ""}`.toLowerCase();

  /// Before any plugin: the brands, each a card with its name and how it connects.
  function brandGrid(plugins) {
    const addable = addablePlugins(plugins);
    const cards = addable.map(({ plugin }) => el("button", { type: "button", class: "setup-brand", title: plugin.summary ? t(plugin.summary) : "",
      onclick: (event) => addPlugin(plugins, plugin, event.currentTarget), "aria-label": t("Add {name}", { name: plugin.name }) },
      tile(plugin.icon ?? "plugin", "orange"),
      el("span", { class: "setup-brand-name", text: plugin.name }),
      el("span", { class: "setup-brand-how muted", text: howItConnects(plugin) })));
    const { search, none } = searchOver(cards, addable.map(({ plugin }) => searchText(plugin)));
    return el("section", { class: "setup-catalog", "aria-label": t("Add a plugin") }, search, el("div", { class: "setup-brands" }, ...cards), none);
  }

  /// Adding a plugin once some are in use: a sheet listing the brands, with a search; the one picked starts its Setup.
  function pickPlugin(plugins, trigger) {
    const addable = addablePlugins(plugins);
    app().openSheet((dismiss) => {
      const rows = addable.map(({ plugin, used }) => el("button", { type: "button", class: "setup-plugin-row", onclick: () => dismiss(plugin) },
        tile(plugin.icon ?? "plugin", "orange"),
        el("span", { class: "who" }, el("strong", {}, plugin.name, used ? el("span", { class: "setup-brand-used", text: t("In use [used]") }) : null),
          el("span", { class: "muted", text: plugin.summary ? t(plugin.summary) : howItConnects(plugin) })),
        el("span", { class: "setup-chevron", "aria-hidden": "true" })));
      const { search, none } = searchOver(rows, addable.map(({ plugin }) => searchText(plugin)));
      queueMicrotask(() => search.focus());
      return el("div", { class: "account-form setup-picker" },
        el("h2", { id: "setup-picker-title", text: t("Add a plugin") }),
        search, el("div", { class: "setup-plugin-rows" }, ...rows), none);
    }, "setup-picker-title", {
      returnFocus: trigger,
      // The picked plugin's Setup opens once this sheet has gone.
      onClose: (plugin) => { if (plugin) addPlugin(plugins, plugin, trigger); else trigger?.focus(); },
    });
  }

  /// A wait for a plugin, its ring turning beside what it is waiting for.
  const loading = (text) => el("p", { class: "setup-loading muted" }, el("span", { class: "spinner", "aria-hidden": "true" }), el("span", { text }));

  /// One plugin instance, one row: its name and where its devices stand. Opened, its account when it has one and the
  /// devices it finds, each with what can be done. One that needs someone opens and moves to the top of the list.
  function instanceCard(block, plugin, { open: openAtFirst = false, start = false } = {}) {
    const list = el("div", { class: "setup-devices", "aria-live": "polite" }, loading(t("Looking for devices…")));
    // Under the name, where its devices stand.
    const summary = el("span", { class: "muted", text: t("Looking for devices…") });
    const action = accountActions[plugin.accountAuthorization];
    let accountSetUp = false;
    // Looking again, and the account's sign-in once it is set up, are in the menu: the row stays one line.
    const menu = menuButton(t("Actions for {name}", { name: block.name }), () => [
      { label: t("Find again"), icon: "search", onSelect: () => { setOpen(true); load(); } },
      action ? { label: action[accountSetUp ? 1 : 0](), icon: action[2], onSelect: () => open({ block, plugin, firstTime: !accountSetUp, after: load }) } : null,
    ].filter(Boolean));
    const bodyID = `setup-${block.slug}-devices`;
    // The row opens and closes it; its menu sits beside the chevron.
    const toggle = el("button", { type: "button", class: "setup-instance-toggle", "aria-expanded": "false", "aria-controls": bodyID },
      tile(block.icon ?? plugin.icon ?? "plugin", "orange"),
      el("span", { class: "who" }, el("strong", { text: block.name }), summary));
    const chevron = el("span", { class: "setup-chevron", "aria-hidden": "true" });
    const head = el("div", { class: "setup-instance-head" }, toggle, menu, chevron);
    const body = el("div", { class: "setup-instance-body", id: bodyID, hidden: true }, list);
    const node = el("section", { class: "card setup-instance", id: `setup-${block.slug}`, "aria-label": block.name }, head, body);
    const setOpen = (on) => { body.hidden = !on; toggle.setAttribute("aria-expanded", String(on)); node.classList.toggle("is-open", on); };
    let touched = false;
    toggle.addEventListener("click", () => { touched = true; setOpen(body.hidden); });
    chevron.addEventListener("click", () => toggle.click());
    setOpen(openAtFirst);

    /// The account's row, first, while it is not set up: nothing else works before it.
    const accountRow = () => el("div", { class: "setup-device setup-account" },
      tile(action[2], "orange"),
      el("div", { class: "who" }, el("strong", { text: methods[plugin.accountAuthorization][0]() }),
        el("div", { class: "muted", text: t("{plugin} needs this before it can reach its devices.", { plugin: plugin.name }) })),
      el("span", { class: "pill status away", text: statuses.needsAuthorization[0]() }),
      el("button", { class: "primary", actionIcon: action[2], text: action[0](), onclick: (event) => open({ block, plugin, firstTime: true, trigger: event.currentTarget, after: load }) }));

    // A search in progress, whatever started it (the page, Find again, a Setup just done): the button turns and the
    // rows it may replace dim, as a device on the network can take seconds to answer.
    let searches = 0;
    const searching = (on) => {
      searches += on ? 1 : -1;
      const busy = searches > 0;
      node.classList.toggle("is-searching", busy);
      list.toggleAttribute("aria-busy", busy);
      if (busy) { summary.textContent = t("Looking for devices…"); summary.dataset.tone = ""; }
    };

    async function load() {
      searching(true);
      try {
        const found = await post("discover", { platform: block.platform, name: block.name });
        accountSetUp = found.accountSetUp;
        const needs = (device) => device.status === "needsAuthorization";
        const waiting = found.devices.filter(needs), settled = found.devices.filter((device) => !needs(device));
        // What the plugin found before a device's Setup: what is new after it came with that device (a console's cameras).
        const known = new Set(found.devices.map((device) => device.deviceID));
        const rows = waiting.map((device) => deviceRow(block, plugin, device, load, known));
        if (action && !accountSetUp) rows.unshift(accountRow());
        rows.push(...settled.map((device) => deviceRow(block, plugin, device, load, known)));
        const excluded = settled.filter((device) => device.status === "excluded").length;
        if (!found.devices.length) rows.push(el("p", { class: "muted setup-none", text: action && !accountSetUp
          ? t("Its devices show here once it is set up.") : t("This plugin finds no devices by itself: its settings name them.") }));
        list.replaceChildren(...rows);
        const attention = waiting.length + (action && !accountSetUp ? 1 : 0);
        summary.textContent = attention ? tn("Needs you once", "Needs you {n} times", attention)
          : settled.length ? [tn("{n} set up", "{n} set up [plural]", settled.length - excluded), excluded ? tn("{n} excluded", "{n} excluded [plural]", excluded) : null].filter(Boolean).join(" · ")
          : action && !accountSetUp ? t("Not set up yet") : t("No devices found");
        summary.dataset.tone = attention ? "away" : "";
        node.classList.toggle("needs-you", attention > 0);
        // What needs someone is shown, unless they closed it themselves.
        if (attention && !touched) setOpen(true);
        // Asked for by the plugin's page: its account's sheet, once.
        if (start && action) { start = false; open({ block, plugin, firstTime: !accountSetUp, after: load }); }
      } catch (e) {
        list.replaceChildren(el("p", { class: "error", role: "alert", text: e.message }));
      } finally {
        searching(false);
      }
    }
    return { node, load };
  }

  /// A device: what it is, where it stands, and what can be done with it.
  function deviceRow(block, plugin, device, reload, known) {
    const [state, tone] = (statuses[device.status] ?? statuses.discovered);
    const excluded = device.status === "excluded";
    // Set up, whether it answers now or not.
    const setUp = device.status === "setUp" || device.status === "notResponding";
    const toggle = (value) => async () => {
      try {
        await post("exclude", { platform: block.platform, name: block.name, deviceID: device.deviceID, excluded: value });
        await reload();
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    const items = [
      setUp && device.authorization !== "none" ? { label: t("Set up again"), icon: "pair", onSelect: () => open({ block, plugin, device, known, after: reload }) } : null,
      // Left out by the plugin's own settings: included again there, not here.
      device.excludedBySettings ? { label: t("Open its settings"), icon: "gear", href: `/plugins/${encodeURIComponent(block.slug)}/expert` }
        : excluded ? { label: t("Include"), icon: "plus", onSelect: toggle(false) } : { label: t("Exclude"), icon: "minus", onSelect: toggle(true) },
    ].filter(Boolean);
    const needs = device.status === "needsAuthorization";
    // The glyph the wall gives its accessory, once it has one.
    const glyph = HomeswiftWidgets.categoryIcon(device.category) ?? (needs ? methods[device.authorization]?.[1] : null) ?? "accessory";
    // Its parts, switched here at once: the plugin reloads with them, or without.
    const parts = !excluded && setUp ? partsList(device, {
      onChange: async (part, included, box) => {
        box.disabled = true;
        try { await post("part", { platform: block.platform, name: block.name, deviceID: device.deviceID, part: part.id, included }); part.included = included; }
        catch (e) { box.checked = !included; HomeswiftCommon.showAlert(e.message); }
        finally { box.disabled = false; }
      },
    }) : null;
    const row = el("div", { class: `setup-device ${excluded ? "is-excluded" : ""}` },
      tile(glyph, excluded ? "grey" : needs ? "orange" : "blue"),
      el("div", { class: "who" }, el("strong", { text: device.name }),
        el("div", { class: "muted", text: device.excludedBySettings ? t("Left out by its settings") : [device.model, device.address].filter(Boolean).join(" · ") || device.deviceID })),
      tone === "on" ? el("span", { class: "status-dot", role: "img", "aria-label": state(), title: state() }) : el("span", { class: `pill status ${tone}`, text: state() }),
      needs
        ? el("button", { class: "primary", actionIcon: "pair", text: t("Set up"), onclick: (event) => open({ block, plugin, device, known, trigger: event.currentTarget, after: reload }) })
        : el("span", { class: "setup-spacer" }),
      menuButton(t("Actions for {name}", { name: device.name }), () => items));
    return parts ? el("div", { class: "setup-device-group" }, row, parts.node) : row;
  }

  /// A device's parts (a gate's side door, a door sensor, a doorbell), each with its switch: those switched off are left
  /// out while the device stays. `onChange(part, included)` is told of each switch; `changes()` what differs from now.
  function partsList(device, { disabled = false, onChange = null } = {}) {
    const parts = device.parts ?? [];
    if (!parts.length) return null;
    const boxes = parts.map((part) => el("input", { type: "checkbox", checked: part.included, disabled, "aria-label": t(part.name) }));
    const node = el("div", { class: "setup-parts", role: "group", "aria-label": t("Parts of {name}", { name: device.name }) },
      ...parts.map((part, index) => el("label", { class: "setup-part" },
        el("span", { class: "setup-part-icon", "aria-hidden": "true" }, HomeswiftCommon.icon(part.icon ?? "accessory")),
        el("span", { class: "setup-part-name", text: t(part.name) }),
        el("span", { class: "switch" }, boxes[index], el("span")))));
    if (onChange) boxes.forEach((box, index) => box.addEventListener("change", () => onChange(parts[index], box.checked, box)));
    return {
      node,
      enable: (on) => boxes.forEach((box) => { box.disabled = !on; }),
      changes: () => parts.flatMap((part, index) => boxes[index].checked === part.included ? [] : [{ part: part.id, included: boxes[index].checked }]),
    };
  }

  /// What an option is called: a country or a language in the reader's language, else its label translated.
  const regionNames = new Intl.DisplayNames([HomeswiftI18n.language, "en"], { type: "region" });
  const languageNames = new Intl.DisplayNames([HomeswiftI18n.language, "en"], { type: "language" });
  const optionName = (option) => {
    try {
      if (option.country) return regionNames.of(option.country) ?? option.label;
      if (option.language) return languageNames.of(option.language) ?? option.label;
    } catch { /* a code the browser does not know */ }
    return t(option.label);
  };

  /// A long list to pick from (a country, a language): a menu sorted by name, the block's answer picked, else the
  /// browser's own country or language, else nothing yet.
  function menu(field) {
    const options = field.options.map((option) => ({ option, name: optionName(option) }))
      .sort((a, b) => a.name.localeCompare(b.name, HomeswiftI18n.language));
    const browser = navigator.language ?? "";
    const picked = field.options.find((option) => option.value === field.value)
      ?? field.options.find((option) => option.language === browser)
      ?? field.options.find((option) => option.country && option.country === browser.split("-")[1]?.toUpperCase());
    return el("select", { name: field.key, id: `setup-${field.key}`, required: !field.optional },
      el("option", { value: "", text: field.optional ? t("Not chosen") : t("Choose…"), disabled: !field.optional, selected: !picked }),
      ...options.map(({ option, name }) => el("option", { value: option.value, text: name, selected: option === picked })));
  }

  /// A choice (how to sign in, a region): its options as radio buttons, each with what it means, the one the block has
  /// picked; a long one without meanings to read is a menu. It reads as an input does: `value`, the option picked or
  /// "", and `focus()`.
  function choice(field) {
    if (field.options.length > 4 && !field.options.some((option) => option.detail)) return menu(field);
    const radios = field.options.map((option) => el("input", { type: "radio", name: `setup-${field.key}`, value: option.value, checked: option.value === field.value }));
    const node = el("fieldset", { class: "field setup-choice", id: `setup-${field.key}` },
      el("legend", { class: "field-title", text: t(field.label) }),
      ...field.options.map((option, index) => el("label", { class: "setup-option" }, radios[index],
        el("span", {}, el("strong", { text: t(option.label) }), option.detail ? el("span", { class: "muted", text: t(option.detail) }) : null))));
    Object.defineProperty(node, "value", { get: () => radios.find((radio) => radio.checked)?.value ?? "" });
    node.focus = () => (radios.find((radio) => radio.checked) ?? radios[0])?.focus();
    return node;
  }

  /// A wait with nothing to type or open: a button to press on the device.
  const pressing = (prompt) => Boolean(prompt.waitSeconds) && !prompt.fields.length && !prompt.url;

  /// The sheet of one Setup: it starts the session, then draws each prompt the plugin sends until it is done. An
  /// account set up for the first time then lists what the plugin finds, to pick those that go into the Home app (the
  /// others are excluded); then what was added. Its header names where it stands: signing in, the devices, done.
  function open({ block, plugin = null, device = null, known = null, draft = false, firstTime = false, resume = null, trigger = null, after }) {
    const title = device?.name ?? block.name;
    // Under the title, a device's Authorization, or the plugin when the instance's name does not say it (an account's
    // way to sign in may be the person's choice, asked in the sheet).
    const subtitle = device ? methods[device.authorization]?.[0]() ?? "" : plugin && bare(plugin.name) !== bare(block.name) ? plugin.name : "";
    const glyph = device ? methods[device.authorization]?.[1] ?? "accessory" : block.icon ?? plugin?.icon ?? "plugin";
    const picking = firstTime && !device;
    const devicesStage = t("Devices");
    const stages = [device ? t("Set up") : accountActions[plugin?.accountAuthorization]?.[0]() ?? t("Sign in"), picking ? devicesStage : null, t("Done")].filter(Boolean);
    let session = null, poll = 0, ticker = 0, done = false, closed = false;
    // A Button Press's end: the retries keep it, so the countdown does not start over at each one.
    let until = 0;
    const stop = () => { clearTimeout(poll); clearInterval(ticker); };
    app().openSheet((dismiss) => {
      const body = el("div", { class: "setup-step" }, loading(t("Asking the plugin…")));
      const steps = el("ol", { class: "setup-stages" });
      const stage = (at) => {
        steps.setAttribute("aria-label", t("Step {at} of {count}", { at: at + 1, count: stages.length }));
        steps.replaceChildren(...stages.map((name, index) => el("li", { class: index < at ? "done" : index === at ? "current" : "", "aria-current": index === at ? "step" : null },
          el("span", { class: "setup-stage-dot", "aria-hidden": "true" }, index < at ? HomeswiftCommon.icon("check") : String(index + 1)), el("span", { text: name }))));
      };
      stage(0);
      const form = el("form", { class: "account-form setup-sheet", novalidate: true },
        el("div", { class: "setup-sheet-head" }, tile(glyph, "orange"),
          el("div", {}, el("h2", { id: "setup-title", text: title }), subtitle ? el("p", { class: "muted setup-method", text: subtitle }) : null)),
        stages.length > 1 ? steps : null,
        body);
      form.addEventListener("submit", (event) => event.preventDefault());
      const fill = (...nodes) => { body.replaceChildren(...nodes.filter(Boolean)); body.classList.remove("entering"); void body.offsetWidth; body.classList.add("entering"); };

      /// The end: what reached the Home app, when the sheet knows.
      function finish(added = null) {
        stage(stages.length - 1);
        // The Setup is over: Done (or Return) closes the sheet, and nothing is sent again.
        form.onsubmit = (event) => { event.preventDefault(); dismiss(); };
        fill(
          el("div", { class: "setup-done" }, el("span", { class: "setup-check", "aria-hidden": "true" }, HomeswiftCommon.icon("check")),
            el("p", {}, el("strong", { text: device ? t("{name} is set up.", { name: title })
              : added?.length ? tn("One accessory added.", "{n} accessories added.", added.length) : t("The account is set up.") })),
            el("p", { class: "muted", text: added?.length ? t("They reach the Home app in a moment.") : t("Its accessories reach the Home app in a moment.") })),
          added?.length ? el("ul", { class: "setup-added" }, ...added.map((found, index) =>
            el("li", { style: `--index: ${Math.min(index, 8)}` }, tile(HomeswiftWidgets.categoryIcon(found.category) ?? glyph, "blue"), el("span", { text: found.name })))) : null,
          el("div", { class: "actions" }, el("button", { class: "primary", type: "submit", actionIcon: "check", text: t("Done") })));
        body.querySelector(".actions button")?.focus();
      }

      /// What the account, or a device just set up (a console), reaches, to pick: every device ticked; those left out are
      /// excluded. A console's devices come once the plugin has connected to it: it is asked a few times.
      async function pick({ keep, tries = 1, owner = plugin?.name ?? block.name }) {
        fill(loading(t("Looking for devices…")));
        let found = [];
        for (let attempt = 0; attempt < tries && !closed; attempt++) {
          if (attempt) await new Promise((resume) => setTimeout(resume, 2000));
          try {
            found = (await post("discover", { platform: block.platform, name: block.name })).devices
              .filter((one) => ["setUp", "notResponding", "discovered"].includes(one.status) && keep(one));
          } catch { found = []; }
          if (found.length) break;
        }
        if (closed) return;
        if (!found.length) { finish(); return; }
        if (!stages.includes(devicesStage)) stages.splice(stages.length - 1, 0, devicesStage);
        stage(stages.indexOf(devicesStage));
        const boxes = found.map((one) => el("input", { type: "checkbox", checked: true, value: one.deviceID }));
        const submit = el("button", { class: "primary", type: "submit", actionIcon: "plus" });
        const count = () => {
          const picked = boxes.filter((box) => box.checked).length;
          submit.textContent = picked ? tn("Add one accessory", "Add {n} accessories", picked) : t("Add none");
        };
        const partLists = found.map((one) => partsList(one));
        boxes.forEach((box, index) => box.addEventListener("change", () => { count(); partLists[index]?.enable(box.checked); }));
        count();
        form.onsubmit = (event) => {
          event.preventDefault();
          HomeswiftCommon.busyButton(submit, async () => {
            const left = found.filter((one, index) => !boxes[index].checked);
            for (const one of left) await post("exclude", { platform: block.platform, name: block.name, deviceID: one.deviceID, excluded: true });
            // The parts of the devices kept, as switched: the plugin builds them, or leaves them out.
            for (const [index, one] of found.entries()) {
              if (!boxes[index].checked) continue;
              for (const change of partLists[index]?.changes() ?? []) await post("part", { platform: block.platform, name: block.name, deviceID: one.deviceID, ...change });
            }
            finish(found.filter((one, index) => boxes[index].checked));
          });
        };
        fill(
          el("p", {}, el("strong", { text: tn("{plugin} found one device.", "{plugin} found {n} devices.", found.length, { plugin: owner }) })),
          el("p", { class: "muted", text: t("Choose those that go into the Home app. The others are excluded; you can include them later.") }),
          el("div", { class: "setup-picks" }, ...found.map((one, index) => el("div", { class: "setup-pick-group" },
            el("label", { class: "setup-pick" }, boxes[index],
              tile(HomeswiftWidgets.categoryIcon(one.category) ?? glyph, "blue"),
              el("span", { class: "who" }, el("strong", { text: one.name }), el("span", { class: "muted", text: [one.model, one.address].filter(Boolean).join(" · ") || one.deviceID }))),
            partLists[index]?.node ?? null))),
          el("div", { class: "actions" }, submit));
        submit.focus({ preventScroll: true });
      }

      function draw(answer) {
        stop();
        // An answer that arrives after the sheet closed (a retry under way) draws nothing and starts nothing.
        if (closed) return;
        if (answer.status === "done") {
          done = true;
          session = null;
          if (picking) pick({ keep: () => true });
          // A console signed in: the cameras, doors and sensors it brings, not the devices that were there already.
          else if (device && known) pick({ keep: (one) => one.authorization === "none" && !known.has(one.deviceID) && one.deviceID !== device.deviceID, tries: 5, owner: title });
          else finish();
          return;
        }
        session = answer.session;
        const prompt = answer.prompt;
        if (!prompt.waitSeconds) until = 0;
        const error = answer.error ? el("p", { class: "error", role: "alert", text: HomeswiftI18n.message(answer.error) }) : null;
        const cancel = el("button", { type: "button", actionIcon: "close", text: t("Cancel"), onclick: () => dismiss() });
        // A wait (a Button Press, a sign-in in another tab): a countdown, and the step sent again every few seconds until
        // the plugin is done. A retry that brings the same prompt back leaves the sheet as it is, and what is typed in it.
        let left = null;
        if (prompt.waitSeconds) {
          if (!until) until = Date.now() + prompt.waitSeconds * 1000;
          left = el("p", { class: "muted setup-countdown" });
          const tick = () => {
            const seconds = Math.max(0, Math.ceil((until - Date.now()) / 1000));
            left.textContent = seconds ? (pressing(prompt) ? t("Waiting for the button… {seconds} s left.", { seconds }) : t("Waiting… {seconds} s left.", { seconds }))
              : t("Time is up. Try again when you are ready.");
            if (!seconds) stop();
          };
          tick();
          const retry = () => {
            if (closed || Date.now() >= until) return;
            poll = setTimeout(async () => {
              let next;
              try { next = await step({}); } catch (e) { next = { ...answer, error: e.message }; }
              if (closed) return;
              if (next.status === "asking" && !next.error && next.prompt.message === prompt.message) retry(); else draw(next);
            }, (prompt.retryAfter ?? 2) * 1000);
          };
          ticker = setInterval(tick, 1000);
          retry();
        }
        if (pressing(prompt)) {
          // The time left as a bar that empties, from where the wait stands now.
          const total = prompt.waitSeconds * 1000;
          const bar = el("span", { class: "setup-wait-bar", "aria-hidden": "true" },
            el("span", { style: `animation-duration: ${total}ms; animation-delay: -${Math.max(0, total - (until - Date.now()))}ms` }));
          fill(
            el("div", { class: "setup-press" }, el("span", { class: "setup-ring", "aria-hidden": "true" }, HomeswiftCommon.icon("pair")),
              el("p", {}, el("strong", { text: t(prompt.message, prompt.values ?? {}) })), bar, left),
            error,
            el("div", { class: "actions" }, cancel));
          return;
        }
        const inputs = prompt.fields.map((field) => {
          if (field.kind === "choice") return [field, choice(field)];
          const input = el("input", {
            name: field.key, id: `setup-${field.key}`, required: !field.optional, spellcheck: false,
            class: field.kind === "code" ? "setup-code" : "",
            type: field.kind === "secret" ? "password" : field.kind === "url" ? "url" : "text",
            autocomplete: field.kind === "secret" ? "current-password" : field.kind === "code" ? "one-time-code" : "off",
            inputmode: field.kind === "code" ? "numeric" : undefined,
          });
          return [field, input];
        });
        const submit = inputs.length ? el("button", { class: "primary", type: "submit", actionIcon: "forward", text: t("Continue") }) : null;
        form.onsubmit = (event) => {
          event.preventDefault();
          if (!submit) return;
          const missing = inputs.find(([field, input]) => !field.optional && !input.value.trim());
          if (missing) { missing[1].focus(); return; }
          stop();
          HomeswiftCommon.busyButton(submit, async () => draw(await step(Object.fromEntries(inputs.map(([field, input]) => [field.key, input.value])))));
        };
        const link = /^https?:\/\//i.test(prompt.url ?? "")
          ? el("a", { class: `button ${inputs.length ? "" : "primary"}`, href: prompt.url, target: "_blank", rel: "noopener noreferrer", actionIcon: "open", text: t("Open the sign-in page") }) : null;
        fill(
          el("p", { text: t(prompt.message, prompt.values ?? {}) }),
          link,
          ...inputs.map(([field, input]) => input.tagName === "FIELDSET" ? input
            : el("label", { class: "field", htmlFor: input.id }, el("span", { class: "field-title", text: t(field.label) }), input)),
          left,
          error,
          el("div", { class: "actions" }, cancel, submit));
        (inputs.find(([, input]) => !input.value)?.[1] ?? submit ?? link ?? cancel).focus();
      }

      const step = (answers) => post(session, { answers });
      // A plugin added from the catalog: its block is saved once its Setup is done.
      // A Setup the Assistant started is taken over where it stands; the others start here.
      (resume ? post(`${resume}/state`, {}) : post("start", { platform: block.platform, name: block.name, deviceID: device?.deviceID, block: draft ? block : undefined }))
        .then(draw)
        .catch((e) => fill(el("p", { class: "error", role: "alert", text: e.message }),
          el("div", { class: "actions" }, el("button", { type: "button", actionIcon: "close", text: t("Close"), onclick: () => dismiss() }))));
      return form;
    }, "setup-title", {
      returnFocus: trigger,
      onClose: () => {
        closed = true;
        stop();
        // A Setup left half way ends on the server too; one that is done shows its device as set up.
        if (session) post(`${session}/cancel`, {}).catch(() => {});
        if (done) after();
        if (trigger?.isConnected) trigger.focus();
      },
    });
  }

  /// A Setup the Assistant started, opened in the sheet at the step it stands at (a password, a sign-in page, a button
  /// to press): the chat's card calls it. The page, when it is open, is drawn again once it is done.
  async function resume({ session, platform, name }) {
    try {
      const plugins = await api("/api/plugins");
      const plugin = plugins.plugins.find((one) => one.platform === platform) ?? null;
      const block = plugins.blocks.find((one) => one.platform === platform && one.name === name) ?? { platform, name: name ?? platform };
      const isNew = !plugins.blocks.some((one) => one.platform === platform && one.name === name);
      open({ block, plugin, resume: session, firstTime: isNew, after: () => { if (location.pathname === "/setup") app().route(); } });
    } catch (e) { HomeswiftCommon.showAlert(e.message); }
  }

  window.HomeswiftSetup = { view, resume };
})();
