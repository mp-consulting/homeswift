// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension MatterDevicesPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* A card per Matter device on the UI's materials: how it is reached, its remote's channels and its last events. */
.node { display: grid; gap: 14px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
.node.redrawn { animation: none; }
.node.is-unreachable { opacity: 0.8; }
.section-head .actions { margin-top: 0; flex-wrap: wrap; }
/* At phone width the two actions share the row, each half of it, rather than run off its edge. */
@media (max-width: 480px) {
  .section-head .actions { width: 100%; }
  .section-head .actions > * { flex: 1 1 0; min-width: 0; justify-content: center; }
}
.add-box { margin-bottom: 14px; animation: materialize var(--normal) var(--ease-out); }
.add-box > p:first-child { margin-top: 0; font-size: 0.875rem; }
.found { display: flex; align-items: center; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
.found .who { flex: 1; min-width: 180px; }

/* Wide enough for a remote's channels and its console: a name and its facts whole, two cards on a desktop. */
#nodes.grid { grid-template-columns: repeat(auto-fill, minmax(min(100%, 420px), 1fr)); }
.node .server-head .who strong { white-space: normal; overflow-wrap: anywhere; }

/* A remote's channels: what each dims, a row each that opens its Settings. */
.channels { display: grid; gap: 6px; margin: 0; padding: 0; list-style: none; }
.channel {
  display: flex; align-items: center; gap: 12px; width: 100%; min-height: 0; padding: 10px 12px; margin: 0; border-radius: 12px;
  background: var(--material-thin); border: 1px solid var(--line); box-shadow: none; color: inherit; font: inherit; text-align: start;
  cursor: pointer; transition: transform 160ms var(--ease-out), background-color 160ms ease;
}
@media (hover: hover) and (pointer: fine) { .channel:hover { background: var(--material); } .channel:hover .chevron { color: var(--text); } }
.channel:active { transform: scale(0.98); }
.channel:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
/* Its number as the remote shows its channels: a dot each, here a small disc. */
.channel .number {
  display: grid; place-items: center; flex: none; width: 26px; height: 26px; border-radius: 50%;
  background: var(--material); border: 1px solid var(--line); font-size: 0.8125rem; font-weight: var(--weight-semibold); font-variant-numeric: tabular-nums;
}
.channel .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.channel .what { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: var(--weight-medium); }
.channel .what.unset { color: var(--accent-ink); }
.channel .endpoints { font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }
.channel .chevron { flex: none; color: var(--muted); display: grid; transition: color 160ms ease; }
.channel .chevron svg { width: 16px; height: 16px; }

/* Its last events, newest first, as the Logs page shows lines: its dark console, sized to the card. */
.events.log {
  margin: var(--space-4) 0 0; list-style: none; height: auto; min-height: 0; max-height: 220px; padding: var(--space-4) 0;
  background: var(--console); border-radius: var(--radius-md); box-shadow: none; -webkit-backdrop-filter: none; backdrop-filter: none;
}
.events .log-line { grid-template-columns: auto minmax(0, 9em) minmax(0, 1fr); padding: 3px var(--space-12); }
.events .count { font-weight: var(--weight-semibold); font-variant-numeric: tabular-nums; }
/* The newest event: a short fade, quick enough for a wheel's events twice a second. */
.events li.fresh { animation: event-in 400ms var(--ease-out); }
@keyframes event-in { from { background: var(--material-thin); } to { background: transparent; } }
/* Where it is reached: its address and Device Id on one quiet line, whole in its tooltip. */
.card-foot .where { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: var(--mono); font-size: var(--text-xs); }

@media (prefers-reduced-motion: reduce) { .node, .add-box, .events li.fresh { animation: none; } .channel:active { transform: none; } }

"""#),
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
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
  /// The device's Accessory Settings (its channels' lights) in the UI's side sheet, over this page; the link's address
  /// stays for a new tab.
  const openSettings = (node, trigger, channel = null) => homeswift.openAccessorySettings({
    accessoryID: node.accessory, name: node.name, glyph: (glyphs[node.kind] ?? ["matter"])[0], trigger, after: (changed) => { if (changed) refresh(); },
    section: channel ? `channel-${channel}` : null,
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

  function channelRow(node, channel) {
    const names = (channel.lights ?? []).map((light) => light.name).join(", ");
    const what = el("span", { class: `what${names ? "" : " unset"}`, text: names || t("Choose a light"), title: names || null });
    const powers = (channel.power ?? []).map((one) => one.name).join(", ");
    const power = powers ? el("span", { class: "endpoints power", text: t("Powered by {name}", { name: powers }) }) : null;
    // The whole row opens the remote's Settings (its lights, power and step), over the page.
    return el("li", {}, el("button", { type: "button", class: "channel", onclick: (event) => openSettings(node, event.currentTarget, channel.number),
      "aria-label": t("Channel {number}: {lights}. Open its settings", { number: channel.number, lights: names || t("nothing chosen") }) },
      el("span", { class: "number", "aria-hidden": "true", text: String(channel.number) }),
      el("span", { class: "body" }, what, power, el("span", { class: "endpoints", text: buttonsText(channel) })),
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
    const card = el("div", { class: `card node${node.status === "unreachable" ? " is-unreachable" : ""}` },
      el("div", { class: "server-head" },
        tile(glyph, reachable ? tone : "grey"),
        el("div", { class: "who" }, el("strong", { text: node.name }), el("div", { class: "muted", text: [node.vendor, node.product].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: label() })),
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
          { label: node.channels?.length ? t("Choose the lights it dims") : t("Settings"), icon: "gear", onSelect: (event) => openSettings(node, event?.currentTarget) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(node.accessory)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Matter device {name}: ", { name: node.name })) } : null,
        ].filter(Boolean))));
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

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Matter Devices page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "Channel {number}: {lights}. Open its settings": "Canal {number} : {lights}. Ouvrir ses réglages",
    "nothing chosen": "rien de choisi",
    "Held": "Maintenu",
    "Pressed {n} times": "Appuyé {n} fois",
    "Pressed": "Appuyé",
    "Turned": "Tourné",
    "Turning": "En rotation",
    "{n} notch": "{n} cran",
    "{n} notches": "{n} crans",
    "Double press": "Double appui",
    "Choose a light": "Choisir une lampe",
    "Channel {number} up": "Canal {number} vers le haut",
    "Channel {number} down": "Canal {number} vers le bas",
    "Channel {number} button": "Bouton du canal {number}",
    "In HomeKit": "Dans HomeKit",
    "{n} accessory": "{n} accessoire",
    "{n} accessories": "{n} accessoires",
    "Matter devices another app already has, which Homeswift controls too, as it reaches them right now. A remote's wheel can dim any light of the bridge.": "Les appareils Matter qu'une autre app a déjà et que Homeswift contrôle aussi, tels qu'il les joint en ce moment. La molette d'une télécommande peut régler n'importe quelle lampe du pont.",
    "Your Matter devices": "Vos appareils Matter",
    "Pairing windows": "Modes d'appairage",
    "Add a Matter device…": "Ajouter un appareil Matter…",
    "About my Matter device {name}: ": "À propos de mon appareil Matter {name} : ",
    "Actions for {name}": "Actions pour {name}",
    "Add": "Ajouter",
    "Added": "Ajouté",
    "Ask the Assistant": "Demander à l'Assistant",
    "Being removed": "En cours de retrait",
    "Choose the lights it dims": "Choisir les lampes qu'elle règle",
    "Connected": "Connecté",
    "Connected since": "Connecté depuis",
    "Connecting…": "Connexion…",
    "Counting": "Comptage",
    "Discriminator {number}": "Discriminateur {number}",
    "Endpoint {number}": "Point {number}",
    "Endpoints {up}, {down}, {press}": "Points {up}, {down}, {press}",
    "Powered by {name}": "Alimenté par {name}",
    "Home app: Button {up} up, {down} down": "Maison : bouton {up} haut, {down} bas",
    "Home app: Button {up} up, {down} down, {press} press": "Maison : bouton {up} haut, {down} bas, {press} appui",
    "Excluded": "Exclu",
    "Last events": "Derniers événements",
    "Last events of {name}": "Derniers événements de {name}",
    "Long press": "Appui long",
    "Long release": "Relâché après appui long",
    "Look again": "Chercher à nouveau",
    "Looking for pairing windows…": "Recherche des modes d'appairage…",
    "No Matter device yet": "Aucun appareil Matter pour l'instant",
    "No events yet.": "Aucun événement pour l'instant.",
    "No pairing window is open. Turn on pairing mode for the device in the app that has it, then look again.": "Aucun mode d'appairage n'est actif. Activez le mode d'appairage de l'appareil dans l'app qui l'a, puis cherchez à nouveau.",
    "Not responding": "Ne répond pas",
    "Nothing pressed since it connected.": "Rien d'appuyé depuis sa connexion.",
    "Press": "Appui",
    "Presses": "Appuis",
    "Reconnect": "Reconnecter",
    "Release": "Relâché",
    "Settings": "Réglages",
    "Show its log": "Afficher son journal",
    "Stopped": "Arrêté",
    "These devices have their pairing mode on. Add one with the code the app that opened it shows.": "Ces appareils ont leur mode d'appairage actif. Ajoutez-en un avec le code qu'affiche l'app qui l'a activé.",
    "Turn on pairing mode for the device in the app that has it (Apple Home: the accessory's settings, Turn On Pairing Mode), then add it here with the code it shows.": "Activez le mode d'appairage de l'appareil dans l'app qui l'a (Maison d'Apple : les réglages de l'accessoire, Activer le mode d'appairage), puis ajoutez-le ici avec le code qu'elle affiche.",
    "Wheel channels": "Canaux de la molette",
    "{step} % per notch": "{step} % par cran",
  },
  "es": {
    "Channel {number}: {lights}. Open its settings": "Canal {number}: {lights}. Abrir sus ajustes",
    "nothing chosen": "nada elegido",
    "Held": "Mantenido",
    "Pressed {n} times": "Pulsado {n} veces",
    "Pressed": "Pulsado",
    "Turned": "Girado",
    "Turning": "Girando",
    "{n} notch": "{n} muesca",
    "{n} notches": "{n} muescas",
    "Double press": "Doble pulsación",
    "Choose a light": "Elegir una luz",
    "Channel {number} up": "Canal {number} arriba",
    "Channel {number} down": "Canal {number} abajo",
    "Channel {number} button": "Botón del canal {number}",
    "In HomeKit": "En HomeKit",
    "{n} accessory": "{n} accesorio",
    "{n} accessories": "{n} accesorios",
    "Matter devices another app already has, which Homeswift controls too, as it reaches them right now. A remote's wheel can dim any light of the bridge.": "Dispositivos Matter que ya tiene otra app y que Homeswift también controla, tal como los alcanza ahora mismo. La rueda de un mando puede regular cualquier luz del puente.",
    "Your Matter devices": "Tus dispositivos Matter",
    "Pairing windows": "Modos de vinculación",
    "Add a Matter device…": "Añadir un dispositivo Matter…",
    "About my Matter device {name}: ": "Sobre mi dispositivo Matter {name}: ",
    "Actions for {name}": "Acciones para {name}",
    "Add": "Añadir",
    "Added": "Añadido",
    "Ask the Assistant": "Preguntar al Asistente",
    "Being removed": "Quitándose",
    "Choose the lights it dims": "Elegir las luces que regula",
    "Connected": "Conectado",
    "Connected since": "Conectado desde",
    "Connecting…": "Conectando…",
    "Counting": "Contando",
    "Discriminator {number}": "Discriminador {number}",
    "Endpoint {number}": "Punto {number}",
    "Endpoints {up}, {down}, {press}": "Puntos {up}, {down}, {press}",
    "Powered by {name}": "Alimentado por {name}",
    "Home app: Button {up} up, {down} down": "Casa: botón {up} arriba, {down} abajo",
    "Home app: Button {up} up, {down} down, {press} press": "Casa: botón {up} arriba, {down} abajo, {press} pulsación",
    "Excluded": "Excluido",
    "Last events": "Últimos eventos",
    "Last events of {name}": "Últimos eventos de {name}",
    "Long press": "Pulsación larga",
    "Long release": "Suelta tras pulsación larga",
    "Look again": "Buscar de nuevo",
    "Looking for pairing windows…": "Buscando modos de vinculación…",
    "No Matter device yet": "Aún no hay dispositivos Matter",
    "No events yet.": "Aún no hay eventos.",
    "No pairing window is open. Turn on pairing mode for the device in the app that has it, then look again.": "No hay ningún modo de vinculación activo. Activa el modo de vinculación del dispositivo en la app que lo tiene y vuelve a buscar.",
    "Not responding": "No responde",
    "Nothing pressed since it connected.": "Nada pulsado desde que se conectó.",
    "Press": "Pulsación",
    "Presses": "Pulsaciones",
    "Reconnect": "Reconectar",
    "Release": "Suelta",
    "Settings": "Ajustes",
    "Show its log": "Ver su registro",
    "Stopped": "Detenido",
    "These devices have their pairing mode on. Add one with the code the app that opened it shows.": "Estos dispositivos tienen activo su modo de vinculación. Añade uno con el código que muestra la app que lo activó.",
    "Turn on pairing mode for the device in the app that has it (Apple Home: the accessory's settings, Turn On Pairing Mode), then add it here with the code it shows.": "Activa el modo de vinculación del dispositivo en la app que lo tiene (Casa de Apple: los ajustes del accesorio, Activar modo de vinculación) y añádelo aquí con el código que muestra.",
    "Wheel channels": "Canales de la rueda",
    "{step} % per notch": "{step} % por muesca",
  },
  "pt": {
    "Channel {number}: {lights}. Open its settings": "Canal {number}: {lights}. Abrir os ajustes",
    "nothing chosen": "nada escolhido",
    "Held": "Mantido",
    "Pressed {n} times": "Premido {n} vezes",
    "Pressed": "Premido",
    "Turned": "Rodado",
    "Turning": "A rodar",
    "{n} notch": "{n} entalhe",
    "{n} notches": "{n} entalhes",
    "Double press": "Pressão dupla",
    "Choose a light": "Escolher uma luz",
    "Channel {number} up": "Canal {number} para cima",
    "Channel {number} down": "Canal {number} para baixo",
    "Channel {number} button": "Botão do canal {number}",
    "In HomeKit": "No HomeKit",
    "{n} accessory": "{n} acessório",
    "{n} accessories": "{n} acessórios",
    "Matter devices another app already has, which Homeswift controls too, as it reaches them right now. A remote's wheel can dim any light of the bridge.": "Dispositivos Matter que outra app já tem e que o Homeswift também controla, tal como os alcança neste momento. A roda de um comando pode regular qualquer luz da ponte.",
    "Your Matter devices": "Os seus dispositivos Matter",
    "Pairing windows": "Modos de emparelhamento",
    "Add a Matter device…": "Adicionar um dispositivo Matter…",
    "About my Matter device {name}: ": "Sobre o meu dispositivo Matter {name}: ",
    "Actions for {name}": "Ações para {name}",
    "Add": "Adicionar",
    "Added": "Adicionado",
    "Ask the Assistant": "Perguntar ao Assistente",
    "Being removed": "A ser removido",
    "Choose the lights it dims": "Escolher as luzes que regula",
    "Connected": "Ligado",
    "Connected since": "Ligado desde",
    "Connecting…": "A ligar…",
    "Counting": "A contar",
    "Discriminator {number}": "Discriminador {number}",
    "Endpoint {number}": "Ponto {number}",
    "Endpoints {up}, {down}, {press}": "Pontos {up}, {down}, {press}",
    "Powered by {name}": "Alimentado por {name}",
    "Home app: Button {up} up, {down} down": "Casa: botão {up} cima, {down} baixo",
    "Home app: Button {up} up, {down} down, {press} press": "Casa: botão {up} cima, {down} baixo, {press} premir",
    "Excluded": "Excluído",
    "Last events": "Últimos eventos",
    "Last events of {name}": "Últimos eventos de {name}",
    "Long press": "Pressão longa",
    "Long release": "Solto após pressão longa",
    "Look again": "Procurar de novo",
    "Looking for pairing windows…": "A procurar modos de emparelhamento…",
    "No Matter device yet": "Ainda não há dispositivos Matter",
    "No events yet.": "Ainda não há eventos.",
    "No pairing window is open. Turn on pairing mode for the device in the app that has it, then look again.": "Nenhum modo de emparelhamento está ativo. Ative o modo de emparelhamento do dispositivo na app que o tem e procure de novo.",
    "Not responding": "Não responde",
    "Nothing pressed since it connected.": "Nada premido desde que se ligou.",
    "Press": "Pressão",
    "Presses": "Pressões",
    "Reconnect": "Voltar a ligar",
    "Release": "Solto",
    "Settings": "Definições",
    "Show its log": "Ver o seu registo",
    "Stopped": "Parado",
    "These devices have their pairing mode on. Add one with the code the app that opened it shows.": "Estes dispositivos têm o modo de emparelhamento ativo. Adicione um com o código que a app que o ativou mostra.",
    "Turn on pairing mode for the device in the app that has it (Apple Home: the accessory's settings, Turn On Pairing Mode), then add it here with the code it shows.": "Ative o modo de emparelhamento do dispositivo na app que o tem (Casa da Apple: as definições do acessório, Ativar modo de emparelhamento) e adicione-o aqui com o código que mostra.",
    "Wheel channels": "Canais da roda",
    "{step} % per notch": "{step} % por entalhe",
  },
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Matter Devices</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-blue" aria-hidden="true"><svg viewBox="0 0 24 24"><circle cx="12" cy="5" r="2.5"/><circle cx="5" cy="18" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="m10.8 7.3-4.6 8.4M13.2 7.3l4.6 8.4M7.5 18h9"/></svg></span>
    <div class="who">
      <h1>Matter Devices</h1>
      <p class="muted" data-i18n>Matter devices another app already has, which Homeswift controls too, as it reaches them right now. A remote's wheel can dim any light of the bridge.</p>
    </div>
  </div>
  <div class="section-head"><h2 data-i18n>Your Matter devices</h2><div class="actions"><button id="windows-toggle" aria-expanded="false" aria-controls="windows" data-i18n data-action-icon="search">Pairing windows</button><a id="add" class="button primary" data-i18n data-action-icon="plus">Add a Matter device…</a></div></div>
  <div id="windows" class="card add-box hidden"></div>
  <div id="nodes" class="grid"></div>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
