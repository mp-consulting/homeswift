// The Philips Ambilight TV page: the TVs the plugin instance knows, refreshed every two seconds while the
// page is visible, with a remote and their inputs. A TV is found and paired on Add accessories (Setup): the page leads
// there. It writes no settings (docs/adr/0002-schema-declares-every-setting.md): a TV's Settings… opens its own on the
// plugin's Settings page, where it is also Excluded or Forgotten.
(() => {
  "use strict";
  const { $, el, tile, request, platform, explain, breadcrumb, act, poll, renderKeyed, setupCard } = homeswift;
  const { t, tn } = HomeswiftI18n;

  // MARK: Where settings are edited: the plugin's Settings page, and each TV's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const tvSettings = (mac) => `${pluginSettings}?accessory=${encodeURIComponent(`${platform}:${mac}`)}`;

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
          // Its settings, Exclude and Forget: the accessory's Settings sheet on the plugin's Settings page.
          { label: t("Settings…"), icon: "gear", href: tvSettings(tv.mac) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(`${platform}:${tv.mac}`)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my TV {name}: ", { name: tv.name })) } : null,
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

  // MARK: Inputs: the TV's inputs in the Home app's wheel order, shown ones first, with their IDs, for its Settings'
  // `sources` (order, visibility, names) and `customApps`. Refresh from TV reads the TV's apps now; Detect from TV
  // names the app on screen.

  const sourcesCard = $("#sources");
  const kindLabels = { tv: "TV", home: t("Home"), hdmi: "HDMI", channel: t("Channel"), app: t("App"), custom: t("Custom") };
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let viewing = null;   // { tv, sources, note }

  async function openSources(tv) {
    viewing = { tv, sources: [], note: null };
    breadcrumb(t("Inputs of {name}", { name: tv.name }), closeSources);
    sourcesCard.classList.remove("hidden");
    sourcesCard.replaceChildren(el("p", { class: "muted", text: t("Loading the inputs of {name}…", { name: tv.name }) }));
    sourcesCard.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
    try {
      const { sources } = await request(`sources?mac=${encodeURIComponent(tv.mac)}`);
      viewing.sources = sources;
      renderSources();
    } catch (e) {
      sourcesCard.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  function closeSources() {
    if (viewing) breadcrumb(null);
    viewing = null;
    sourcesCard.classList.add("hidden");
    sourcesCard.replaceChildren();
  }

  const sourceRow = (source) => el("li", { class: "source", "data-id": source.id },
    el("span", { class: `kind ${source.kind}`, text: kindLabels[source.kind] ?? source.kind }),
    el("span", { class: "source-name", text: source.customName || source.name }),
    source.customName ? el("span", { class: "original muted", text: source.name, title: t("The name the TV gives it") }) : null,
    el("span", { class: "source-id muted mono", text: source.id }));

  function renderSources() {
    const shown = viewing.sources.filter((source) => source.visible);
    const hidden = viewing.sources.filter((source) => !source.visible);
    const detected = el("p", { class: "status-line muted" });
    sourcesCard.replaceChildren(
      el("div", { class: "panel-head" },
        el("div", {}, el("h2", { text: t("Inputs of {name}", { name: viewing.tv.name }) }),
          el("p", { class: "muted", text: viewing.note ?? t("The order of the input wheel in the Home app. Its order, the inputs shown and their names are the TV's Settings (Source Configuration), by these IDs.") })),
        el("div", { class: "head-actions" },
          el("a", { class: "button", actionIcon: "gear", href: tvSettings(viewing.tv.mac), text: t("Settings…") }),
          el("button", { actionIcon: "restore", class: "link", text: t("Refresh from TV"), title: t("Read the TV's apps again"), onclick: (event) => act(event.currentTarget, refreshSources) }),
          el("button", { actionIcon: "close", class: "link", text: t("Close"), onclick: closeSources }))),
      el("div", { class: "panel-columns" },
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status on", text: t("Shown · {n}", { n: shown.length }) })),
          shown.length ? el("ol", { class: "sources", "aria-label": t("Shown inputs, in order") }, shown.map(sourceRow)) : el("p", { class: "muted empty-list", text: t("No input is shown.") })),
        el("section", {}, el("div", { class: "column-head" }, el("span", { class: "pill status standby", text: t("Hidden · {n}", { n: hidden.length }) })),
          hidden.length ? el("ul", { class: "sources pool", "aria-label": t("Hidden inputs") }, hidden.map(sourceRow)) : el("p", { class: "muted empty-list", text: t("Every input is shown.") }))),
      el("div", { class: "detect" },
        el("p", { class: "help", text: t("An app the TV does not list goes in the TV's Settings (Custom Apps): open it on the TV, then Detect from TV gives its package name and launch activity.") }),
        el("button", { actionIcon: "search", text: t("Detect from TV"), onclick: (event) => act(event.currentTarget, async () => {
          detected.className = "status-line muted";
          detected.textContent = t("Asking the TV which app is open…");
          const { app } = await request(`current-app?mac=${encodeURIComponent(viewing.tv.mac)}`);
          detected.className = "status-line ok";
          detected.replaceChildren(t("Found {name}.", { name: app.name ?? app.packageName }), " ",
            el("span", { class: "mono", text: [app.packageName, app.className].filter(Boolean).join(" / ") }));
        }, (text) => { detected.className = "status-line error"; detected.replaceChildren(text); }) }),
        detected));
  }

  /// "Refresh from TV": the plugin reads the TV's apps now.
  async function refreshSources() {
    const tv = viewing.tv;
    const known = new Set(viewing.sources.map((source) => source.id));
    const { sources } = await request("sources/refresh", { method: "POST", body: { mac: tv.mac } });
    if (!viewing || viewing.tv !== tv) return;
    const added = sources.filter((source) => !known.has(source.id));
    viewing.sources = sources;
    viewing.note = added.length
      ? tn("{n} new input from the TV: {names}.", "{n} new inputs from the TV: {names}.", added.length, { names: added.map((source) => source.name).join(", ") })
      : t("The TV has no new app.");
    renderSources();
  }

  // MARK: Adding a TV: Add accessories finds it (or takes the address in the plugin's settings) and pairs it with its PIN.

  $("#setup").replaceChildren(setupCard({
    title: t("Add a TV"),
    text: t("Add accessories finds the Philips TVs on this network and pairs them with the PIN they show. Switch the TV on first."),
    glyph: "pair", tone: "blue", start: false,
  }));

  poll(refresh);
})();
