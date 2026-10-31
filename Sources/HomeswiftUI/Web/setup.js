// Setup (GLOSSARY.md, "Setup"): /setup lists what each plugin finds, with where each device stands, and sets up the
// devices and accounts that ask for a code, a button press, a sign-in or keys, in one sheet whatever the plugin. The
// server holds each Setup in progress (POST /api/setup/…, SetupRoutes.swift); this page only draws its prompts.
// app.js routes /setup here and lends its helpers (HomeswiftApp) when the view is drawn.
(() => {
  "use strict";

  const { el, tile, menuButton } = HomeswiftCommon;
  const { t } = HomeswiftI18n;
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
    discovered: [() => t("Ready"), "on"],
    needsAuthorization: [() => t("Needs setup"), "away"],
    excluded: [() => t("Excluded"), "paused"],
  };
  /// The glyph of an accessory's category, as the bridge has it; a device not on the bridge yet has the plain one.
  const glyphs = {
    lightbulb: "bulb", sensor: "sensor", switch: "switch", programmableSwitch: "switch", outlet: "outlet", fan: "fan", airPurifier: "fan",
    thermostat: "thermo", heater: "thermo", airConditioner: "thermo", doorLock: "lock", door: "door", garageDoorOpener: "door",
    windowCovering: "blind", ipCamera: "camera", videoDoorbell: "camera", television: "tv", speaker: "speaker",
  };

  async function view(main) {
    const plugins = await api("/api/plugins");
    const byPlatform = new Map(plugins.plugins.map((plugin) => [plugin.platform, plugin]));
    const blocks = plugins.blocks.filter((block) => !block.system && byPlatform.has(block.platform));
    const cards = blocks.map((block) => instanceCard(block, byPlatform.get(block.platform)));
    app().show(main,
      app().pageHead(t("Add accessories"), t("What each plugin finds now. Set up the devices that ask for a code, a button or a sign-in; exclude those you do not want in the Home app.")),
      cards.length ? el("div", { class: "setup-list" }, ...cards.map((card) => card.node))
        : el("div", { class: "card empty" }, el("span", { class: "empty-glyph" }, HomeswiftCommon.icon("plugin")),
          el("p", { class: "muted", text: t("No plugin yet. Add one, then come back to set up its devices.") }),
          el("a", { class: "button primary", href: "/plugins", actionIcon: "plus", text: t("Add a plugin") })));
    // From a plugin's menu (/setup#<slug>): its card first in view.
    const wanted = decodeURIComponent(location.hash.slice(1));
    if (wanted) document.getElementById(`setup-${wanted}`)?.scrollIntoView({ block: "start" });
    // Every plugin looks at once: a slow cloud does not hold the others back.
    await Promise.all(cards.map((card) => card.load()));
  }

  /// One plugin instance: its account, when it has one, and the devices it finds.
  function instanceCard(block, plugin) {
    const list = el("div", { class: "setup-devices", "aria-live": "polite" }, el("p", { class: "setup-loading muted", text: t("Looking for devices…") }));
    const action = accountActions[plugin.accountAuthorization];
    let accountSetUp = false;
    const find = el("button", { actionIcon: "search", text: t("Find again"), onclick: (event) => HomeswiftCommon.busyButton(event.currentTarget, load) });
    // Once the account is set up, doing it again is in the menu: the list is what the card is for then.
    const again = action ? menuButton(t("Actions for {name}", { name: block.name }), () => accountSetUp
      ? [{ label: action[1](), icon: action[2], onSelect: () => open(block, null, block.name, null, load, plugin.name) }]
      : [{ label: action[0](), icon: action[2], onSelect: () => open(block, null, block.name, null, load, plugin.name) }]) : null;
    const node = el("section", { class: "card setup-instance", id: `setup-${block.slug}`, "aria-label": block.name },
      el("div", { class: "server-head" }, tile(block.icon ?? plugin.icon ?? "plugin", "orange"),
        // Under the name, the plugin, when the name does not say it already.
        el("div", { class: "who" }, el("strong", { text: block.name }), bare(block.name) === bare(plugin.name) ? null : el("div", { class: "muted", text: plugin.name })),
        el("div", { class: "setup-tools" }, find, again)),
      list);

    /// The account's row, first, while it is not set up: nothing else works before it.
    const accountRow = () => el("div", { class: "setup-device setup-account" },
      tile(action[2], "orange"),
      el("div", { class: "who" }, el("strong", { text: methods[plugin.accountAuthorization][0]() }),
        el("div", { class: "muted", text: t("{plugin} needs this before it can reach its devices.", { plugin: plugin.name }) })),
      el("span", { class: "pill status away", text: statuses.needsAuthorization[0]() }),
      el("button", { class: "primary", actionIcon: action[2], text: action[0](), onclick: (event) => open(block, null, block.name, event.currentTarget, load, plugin.name) }));

    async function load() {
      try {
        const found = await post("discover", { platform: block.platform, name: block.name });
        accountSetUp = found.accountSetUp;
        const rows = found.devices.map((device) => deviceRow(block, device, load));
        if (action && !accountSetUp) rows.unshift(accountRow());
        if (!found.devices.length) rows.push(el("p", { class: "muted setup-none", text: action && !accountSetUp
          ? t("Its devices show here once it is set up.") : t("This plugin finds no devices by itself: its settings name them.") }));
        list.replaceChildren(...rows);
      } catch (e) {
        list.replaceChildren(el("p", { class: "error", role: "alert", text: e.message }));
      }
    }
    return { node, load };
  }

  /// A device: what it is, where it stands, and what can be done with it.
  function deviceRow(block, device, reload) {
    const [state, tone] = (statuses[device.status] ?? statuses.discovered);
    const excluded = device.status === "excluded";
    const toggle = (value) => async () => {
      try {
        await post("exclude", { platform: block.platform, name: block.name, deviceID: device.deviceID, excluded: value });
        await reload();
      } catch (e) { HomeswiftCommon.showAlert(e.message); }
    };
    const items = [
      device.status === "setUp" && device.authorization !== "none" ? { label: t("Set up again"), icon: "pair", onSelect: () => open(block, device, device.name, null, reload) } : null,
      // Left out by the plugin's own settings: included again there, not here.
      device.excludedBySettings ? { label: t("Open its settings"), icon: "gear", href: `/plugins/${encodeURIComponent(block.slug)}/expert` }
        : excluded ? { label: t("Include"), icon: "plus", onSelect: toggle(false) } : { label: t("Exclude"), icon: "minus", onSelect: toggle(true) },
    ].filter(Boolean);
    const needs = device.status === "needsAuthorization";
    const glyph = glyphs[device.category] ?? (needs ? methods[device.authorization]?.[1] : null) ?? "accessory";
    return el("div", { class: `setup-device ${excluded ? "is-excluded" : ""}` },
      tile(glyph, excluded ? "grey" : needs ? "orange" : "blue"),
      el("div", { class: "who" }, el("strong", { text: device.name }),
        el("div", { class: "muted", text: device.excludedBySettings ? t("Left out by its settings") : [device.model, device.address].filter(Boolean).join(" · ") || device.deviceID })),
      tone === "on" ? el("span", { class: "status-dot", role: "img", "aria-label": state(), title: state() }) : el("span", { class: `pill status ${tone}`, text: state() }),
      device.status === "needsAuthorization"
        ? el("button", { class: "primary", actionIcon: "pair", text: t("Set up"), onclick: (event) => open(block, device, device.name, event.currentTarget, reload) })
        : el("span", { class: "setup-spacer" }),
      menuButton(t("Actions for {name}", { name: device.name }), () => items));
  }

  /// A wait with nothing to type or open: a button to press on the device.
  const pressing = (prompt) => Boolean(prompt.waitSeconds) && !prompt.fields.length && !prompt.url;

  /// The sheet of one Setup: it starts the session, then draws each prompt the plugin sends until it is done.
  function open(block, device, title, trigger, after, subtitle = "") {
    let session = null, poll = 0, ticker = 0, done = false, closed = false;
    // A Button Press's end: the retries keep it, so the countdown does not start over at each one.
    let until = 0;
    const stop = () => { clearTimeout(poll); clearInterval(ticker); };
    app().openSheet((dismiss) => {
      const body = el("div", { class: "setup-step" }, el("p", { class: "setup-loading muted", text: t("Asking the plugin…") }));
      const form = el("form", { class: "account-form setup-sheet", novalidate: true },
        el("h2", { id: "setup-title", text: title }),
        el("p", { class: "muted setup-method", text: device ? methods[device.authorization]?.[0]() ?? "" : subtitle }),
        body);
      form.addEventListener("submit", (event) => event.preventDefault());
      const fill = (...nodes) => body.replaceChildren(...nodes.filter(Boolean));

      function draw(answer) {
        stop();
        // An answer that arrives after the sheet closed (a retry under way) draws nothing and starts nothing.
        if (closed) return;
        if (answer.status === "done") {
          done = true;
          session = null;
          fill(
            el("div", { class: "setup-done" }, el("span", { class: "setup-check", "aria-hidden": "true" }, HomeswiftCommon.icon("check")),
              el("p", {}, el("strong", { text: device ? t("{name} is set up.", { name: title }) : t("The account is set up.") })),
              el("p", { class: "muted", text: t("Its accessories reach the Home app in a moment.") })),
            el("div", { class: "actions" }, el("button", { class: "primary", actionIcon: "check", text: t("Done"), onclick: () => dismiss() })));
          body.querySelector("button")?.focus();
          return;
        }
        session = answer.session;
        const prompt = answer.prompt;
        if (!prompt.waitSeconds) until = 0;
        const error = answer.error ? el("p", { class: "error", role: "alert", text: answer.error }) : null;
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
          fill(
            el("div", { class: "pair-prompt pairing" }, el("span", { class: "link-button", "aria-hidden": "true" }, HomeswiftCommon.icon("pair")),
              el("div", {}, el("p", {}, el("strong", { text: t(prompt.message, prompt.values ?? {}) })), left)),
            error,
            el("div", { class: "actions" }, cancel));
          return;
        }
        const inputs = prompt.fields.map((field) => {
          const input = el("input", {
            name: field.key, id: `setup-${field.key}`, required: !field.optional, spellcheck: false,
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
          ...inputs.map(([field, input]) => el("label", { class: "field", htmlFor: input.id }, el("span", { class: "field-title", text: t(field.label) }), input)),
          left,
          error,
          el("div", { class: "actions" }, cancel, submit));
        (inputs.find(([, input]) => !input.value)?.[1] ?? submit ?? link ?? cancel).focus();
      }

      const step = (answers) => post(session, { answers });
      post("start", { platform: block.platform, name: block.name, deviceID: device?.deviceID })
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

  window.HomeswiftSetup = { view, open };
})();
