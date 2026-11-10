// The Matter Devices page: the Matter devices this instance added (refreshed every two seconds while the page is
// visible, a card drawn again only when it changed), how each is reached, a remote's channels and the lights they dim,
// and its last events as it sends them; the pairing windows open on the network. It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): a channel's light is the device's Accessory Setting, which the UI's
// own Settings sheet edits over this page (homeswift.openAccessorySettings); adding a device is Setup, on Add accessories.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, poll, renderKeyed } = homeswift;

  const list = $("#nodes");
  $("#add").href = homeswift.setupAddress();
  /// The device's Accessory Settings in the UI's side sheet, over this page; the link's address stays for a new tab.
  const openSettings = (node, trigger) => homeswift.openAccessorySettings({
    accessoryID: node.accessory, name: node.name, glyph: (glyphs[node.kind] ?? ["matter"])[0], trigger, after: (changed) => { if (changed) refresh(); },
  });

  const statuses = {
    connected: [() => t("Connected"), "on"],
    connecting: [() => t("Connecting…"), "standby"],
    unreachable: [() => t("Not responding"), "away"],
    stopped: [() => t("Stopped"), "paused"],
    excluded: [() => t("Excluded"), "paused"],
    forgotten: [() => t("Being removed"), "paused"],
  };
  const glyphs = { remote: ["switch", "violet"], light: ["bulb", "yellow"], plug: ["outlet", "green"], switch: ["switch", "green"], sensor: ["sensor", "teal"] };

  // In the reader's own formats and the home's time zone, as every page shows dates.
  const clock = HomeswiftI18n.dateTimeFormat({ hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const time = (iso) => clock.format(new Date(iso));
  // A time today, a short date otherwise.
  const since = (iso) => {
    if (!iso) return "—";
    const date = new Date(iso);
    const day = (value) => HomeswiftI18n.formatDate(value, { year: "numeric", month: "numeric", day: "numeric" });
    return day(date) === day(new Date())
      ? HomeswiftI18n.formatDate(date, { hour: "2-digit", minute: "2-digit" })
      : day(date);
  };

  // The events' names, as the plugin gives them, in the reader's language.
  const eventNames = {
    "Press": () => t("Press"), "Long press": () => t("Long press"), "Release": () => t("Release"), "Long release": () => t("Long release"),
    "Counting": () => t("Counting"), "Presses": () => t("Presses"),
  };
  const eventName = (name) => (eventNames[name] ?? (() => name))();

  // MARK: A device

  /// A Remote's card on the Remotes page, where its Controls are set; a channel's part opened there.
  const remoteAddress = (node, part = null) => `/remotes/${encodeURIComponent(node.accessory)}${part ? `?part=${encodeURIComponent(part)}` : ""}`;

  function channelRow(node, channel) {
    const names = (channel.targets ?? []).map((target) => target.name).join(", ");
    const what = el("span", { class: `what${names ? "" : " unset"}`, text: names || t("Nothing set yet"), title: names || null });
    // The whole row opens the channel's Wheel on the Remotes page, where what it does is set.
    return el("li", {}, el("a", { class: "channel", href: remoteAddress(node, `wheel:${channel.up}`),
      "aria-label": t("Channel {number}: {lights}. Set what it does", { number: channel.number, lights: names || t("nothing set") }) },
      el("span", { class: "number", "aria-hidden": "true", text: String(channel.number) }),
      el("span", { class: "body" }, what, el("span", { class: "endpoints", text: buttonsText(channel) })),
      el("span", { class: "chevron", "aria-hidden": "true" }, HomeswiftCommon.icon("forward"))));
  }

  /// Which buttons of the Home app are the channel's: up, down and its button, as the Home app numbers them.
  function buttonsText(channel) {
    const b = channel.buttons ?? {};
    if (b.up == null || b.down == null) return t("Endpoints {up}, {down}, {press}", { up: channel.up, down: channel.down, press: channel.press ?? "—" });
    return b.press == null
      ? t("Home app: Button {up} up, {down} down", { up: b.up, down: b.down })
      : t("Home app: Button {up} up, {down} down, {press} press", { up: b.up, down: b.down, press: b.press });
  }

  /// What sent an event: a remote's channel and direction, else its endpoint.
  function source(node, endpoint) {
    for (const channel of node.channels ?? []) {
      if (channel.up === endpoint) return t("Channel {number} up", { number: channel.number });
      if (channel.down === endpoint) return t("Channel {number} down", { number: channel.number });
      if (channel.press === endpoint) return t("Channel {number} button", { number: channel.number });
    }
    return t("Endpoint {number}", { number: endpoint });
  }

  /// The events as gestures, newest first: a button's press, double press or hold, a wheel's turn with its notches (its
  /// running counts folded into one line), rather than every Switch event the remote sends (Press, Release, Presses 1).
  function gestures(node) {
    const rotary = new Set((node.channels ?? []).flatMap((channel) => [channel.up, channel.down]));
    const lines = [];
    for (const event of node.events ?? []) {
      const count = Number(event.detail) || 0;
      if (rotary.has(event.endpoint)) {
        if (event.name !== "Counting" && event.name !== "Presses") continue;
        // A turn reports its running count twice a second: its newest line stands for it.
        const last = lines[lines.length - 1];
        if (last?.endpoint === event.endpoint && last.turn && (last.counting || event.name === "Counting")) continue;
        lines.push({ ...event, turn: true, counting: event.name === "Counting",
          text: event.name === "Counting" ? t("Turning") : t("Turned"), count: tn("{n} notch", "{n} notches", count) });
      } else if (event.name === "Presses") {
        if (count === 0) continue;   // aborted (Application Clusters §1.13.7.5): no press
        lines.push({ ...event, text: count === 1 ? t("Pressed") : count === 2 ? t("Double press") : t("Pressed {n} times", { n: count }) });
      } else if (event.name === "Long press") {
        lines.push({ ...event, text: t("Held") });
      } else if (!["Press", "Release", "Long release", "Counting"].includes(event.name) || !node.channels?.length) {
        lines.push({ ...event, text: eventName(event.name), count: event.detail });
      }
    }
    return lines;
  }

  function eventsList(node) {
    const lines = gestures(node);
    if (!lines.length) return el("p", { class: "muted", text: node.status === "connected" ? t("Nothing pressed since it connected.") : t("No events yet.") });
    // The Logs page's lines (style.css's .log and .log-line): its console, times, labels and text.
    return el("ol", { class: "log events", "aria-label": t("Last events of {name}", { name: node.name }) },
      ...lines.slice(0, 12).map((line, index) => el("li", { class: `log-line info${index === 0 && fresh(node, line) ? " fresh" : ""}` },
        el("time", { dateTime: line.time, title: line.time, text: time(line.time) }),
        el("span", { class: "label", text: source(node, line.endpoint), title: source(node, line.endpoint) }),
        el("span", { class: "text" }, line.text, line.count ? el("span", { class: "count", text: ` · ${line.count}` }) : null))));
  }

  // The newest event lights up once, when it arrives.
  const lastSeen = new Map();
  function fresh(node, event) {
    const key = `${event.time}|${event.endpoint}|${event.name}`;
    const isNew = lastSeen.has(node.device) && lastSeen.get(node.device) !== key;
    lastSeen.set(node.device, key);
    return isNew;
  }

  function nodeCard(node) {
    const [label, kind] = (statuses[node.status] ?? statuses.connecting);
    const [glyph, tone] = glyphs[node.kind] ?? ["matter", "blue"];
    const reachable = node.status === "connected";
    const previous = [...list.children].find((card) => card.dataset.key === String(node.device));
    const card = el("details", { class: `card node${node.status === "unreachable" ? " is-unreachable" : ""}`, open: previous?.open || null },
      el("summary", { class: "server-head" },
        tile(glyph, reachable ? tone : "grey"),
        el("div", { class: "who" }, el("strong", { text: node.name }), el("div", { class: "muted", text: [node.vendor, node.product].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: label() }),
        el("span", { class: "node-chevron", "aria-hidden": "true" }, HomeswiftCommon.icon("forward"))),
      el("div", { class: "node-body" },
      el("div", { class: "facts" },
        fact(t("In HomeKit"), node.accessories ? tn("{n} accessory", "{n} accessories", node.accessories.length) : "—"),
        fact(reachable ? t("Connected since") : t("Added"), reachable ? since(node.since) : since(node.added))),
      node.status === "unreachable" ? explain({
        error: `The Matter device ${node.name} (${[node.vendor, node.product].filter(Boolean).join(" ")}) does not answer: ${node.error ?? "unknown"}.`,
        context: "Homeswift is an extra Matter controller of this device (multi-admin). It finds the node by DNS-SD (_matter._tcp) and opens a CASE session; a Thread device answers through a Thread border router, so the bridge's host needs IPv6 routes to the Thread network. A battery device sleeps and answers only when it polls its parent.",
        device: { vendor: node.vendor, product: node.product, address: node.address },
      }) : null,
      node.channels?.length ? el("div", {},
        el("h3", { class: "service-name", text: t("Wheel channels") }),
        el("ul", { class: "channels" }, ...node.channels.map((channel) => channelRow(node, channel)))) : null,
      node.events ? el("div", {}, el("h3", { class: "service-name", text: t("Last events") }), eventsList(node)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted where", title: [node.address, node.device].filter(Boolean).join(" · "), text: [node.address, node.device].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: node.name }), () => [
          node.status !== "forgotten" && node.status !== "excluded" && node.status !== "stopped"
            ? { label: t("Reconnect"), icon: "loop", onSelect: () => request("reconnect", { method: "POST", body: { device: node.device } }).then(refresh).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
          node.channels?.length ? { label: t("Set what its buttons do"), icon: "sliders", href: remoteAddress(node) } : null,
          { label: t("Settings"), icon: "gear", onSelect: (event) => openSettings(node, event?.currentTarget) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(node.accessory)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Matter device {name}: ", { name: node.name })) } : null,
        ].filter(Boolean)))));
    return card;
  }

  // A card drawn again because it changed stays still: only a device new to the page arrives with the animation.
  const shown = new Set();
  function card(node) {
    const drawn = nodeCard(node);
    if (shown.has(node.device)) drawn.classList.add("redrawn");
    shown.add(node.device);
    return drawn;
  }

  async function refresh() {
    try {
      const { nodes = [] } = await request("nodes");
      if (nodes.length === 0) {
        if (!list.querySelector(".setup-handoff")) {
          list.replaceChildren(homeswift.setupCard({
            title: t("No Matter device yet"),
            text: t("Turn on pairing mode for the device in the app that has it (Apple Home: the accessory's settings, Turn On Pairing Mode), then add it here with the code it shows."),
            action: t("Add a Matter device…"), start: false, glyph: "plus", tone: "blue",
          }));
        }
        return;
      }
      renderKeyed(list, nodes, (node) => node.device, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: Pairing windows: the devices whose pairing mode is on now, which Add a Matter device… can take in.

  const windowsBox = $("#windows");
  const windowsToggle = $("#windows-toggle");

  async function showWindows() {
    windowsBox.replaceChildren(el("p", { class: "muted", text: t("Looking for pairing windows…") }));
    try {
      const { windows = [] } = await request("windows");
      windowsBox.replaceChildren(
        el("p", { class: "muted", text: windows.length
          ? t("These devices have their pairing mode on. Add one with the code the app that opened it shows.")
          : t("No pairing window is open. Turn on pairing mode for the device in the app that has it, then look again.") }),
        ...windows.map((window) => el("div", { class: "found" },
          el("div", { class: "who" }, el("strong", { text: window.name }),
            el("div", { class: "muted", text: [window.vendor, window.address, t("Discriminator {number}", { number: window.discriminator })].filter(Boolean).join(" · ") })),
          el("a", { class: "button", href: homeswift.setupAddress(), actionIcon: "plus", text: t("Add") }))),
        el("div", { class: "actions" }, el("button", { type: "button", actionIcon: "search", text: t("Look again"), onclick: (event) => homeswift.act(event.currentTarget, showWindows) })));
    } catch (e) {
      windowsBox.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  windowsToggle.addEventListener("click", () => {
    const opening = windowsBox.classList.contains("hidden");
    windowsBox.classList.toggle("hidden", !opening);
    windowsToggle.setAttribute("aria-expanded", String(opening));
    if (opening) showWindows();
  });

  poll(refresh);
})();
