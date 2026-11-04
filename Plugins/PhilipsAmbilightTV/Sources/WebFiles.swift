// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension PhilipsAmbilightTVPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Ambilight TV page: the TVs the plugin instance knows, refreshed every two seconds while the
// page is visible, with a remote and their inputs. A TV is found and paired on Add accessories (Setup): the page leads
// there. It writes no settings (docs/adr/0002-schema-declares-every-setting.md): a TV's Settings… opens its own on the
// plugin's Settings page, where it is also Excluded or Forgotten.
(() => {
  "use strict";
  const { $, el, tile, request, platform, explain, breadcrumb, act, poll, renderKeyed, setupCard } = homeswift;
  const { t, tn } = HomeswiftI18n;

  // MARK: Where settings are edited: the plugin's Settings page, and each TV's there.

  const tvSettings = (mac) => homeswift.accessorySettings(`${platform}:${mac}`);

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

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Philips Ambilight TV page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Your Philips Android TVs: control them from here and from the Home app. Each one's options are in its Settings.": "Vos téléviseurs Philips Android : pilotez-les d'ici et depuis l'app Maison. Les options de chacun sont dans ses Réglages.",
    "The order of the input wheel in the Home app. Its order, the inputs shown and their names are the TV's Settings (Source Configuration), by these IDs.": "L'ordre de la roue des entrées dans l'app Maison. Cet ordre, les entrées affichées et leurs noms sont dans les Réglages du téléviseur (Configuration des sources), par ces identifiants.",
    "An app the TV does not list goes in the TV's Settings (Custom Apps): open it on the TV, then Detect from TV gives its package name and launch activity.": "Une app que le téléviseur ne liste pas va dans ses Réglages (Apps personnalisées) : ouvrez-la sur le téléviseur, puis Détecter sur le téléviseur donne son nom de paquet et son activité de lancement.",
    "Your TVs": "Vos téléviseurs",
    "Add a TV": "Ajouter un téléviseur",
    "Add accessories finds the Philips TVs on this network and pairs them with the PIN they show. Switch the TV on first.": "Ajouter des accessoires trouve les téléviseurs Philips de ce réseau et les jumelle avec le PIN qu'ils affichent. Allumez d'abord le téléviseur.",
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
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my TV {name}: ": "À propos de mon téléviseur {name} : ",
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
    "Shown inputs, in order": "Entrées affichées, dans l'ordre",
    "Hidden inputs": "Entrées masquées",
    "Refresh from TV": "Actualiser depuis le téléviseur",
    "Read the TV's apps again": "Relire les apps du téléviseur",
    "Close": "Fermer",
    "Shown · {n}": "Affichées · {n}",
    "No input is shown.": "Aucune entrée n'est affichée.",
    "Hidden · {n}": "Masquées · {n}",
    "Every input is shown.": "Toutes les entrées sont affichées.",
    "The name the TV gives it": "Le nom que lui donne le téléviseur",
    "{n} new input from the TV: {names}.": "{n} nouvelle entrée du téléviseur : {names}.",
    "{n} new inputs from the TV: {names}.": "{n} nouvelles entrées du téléviseur : {names}.",
    "The TV has no new app.": "Le téléviseur n'a pas de nouvelle app.",
    "Detect from TV": "Détecter sur le téléviseur",
    "Asking the TV which app is open…": "Interrogation du téléviseur sur l'app ouverte…",
    "Found {name}.": "{name} trouvée.",
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
    "the TV did not answer: {0}": "le téléviseur n'a pas répondu : {0}",
    "the TV refuses connections on port {0}": "le téléviseur refuse les connexions sur le port {0}",
    "the TV answered HTTP {0}": "le téléviseur a répondu HTTP {0}",
    "the TV refused the credentials: pair it again": "le téléviseur a refusé les identifiants : jumelez-le à nouveau",
    "unexpected answer from the TV: {0}": "réponse inattendue du téléviseur : {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "le certificat du téléviseur ({0}) n'est pas celui épinglé ({1})"
  },
  "es": {
    "Your Philips Android TVs: control them from here and from the Home app. Each one's options are in its Settings.": "Tus televisores Philips Android: contrólalos desde aquí y desde la app Casa. Las opciones de cada uno están en sus Ajustes.",
    "The order of the input wheel in the Home app. Its order, the inputs shown and their names are the TV's Settings (Source Configuration), by these IDs.": "El orden de la rueda de entradas en la app Casa. Ese orden, las entradas que se muestran y sus nombres están en los Ajustes del televisor (Configuración de fuentes), por estos identificadores.",
    "An app the TV does not list goes in the TV's Settings (Custom Apps): open it on the TV, then Detect from TV gives its package name and launch activity.": "Una app que el televisor no lista va en sus Ajustes (Apps personalizadas): ábrela en el televisor y Detectar en el televisor da su nombre de paquete y su actividad de inicio.",
    "Your TVs": "Tus televisores",
    "Add a TV": "Añadir un televisor",
    "Add accessories finds the Philips TVs on this network and pairs them with the PIN they show. Switch the TV on first.": "Añadir accesorios encuentra los televisores Philips de esta red y los empareja con el PIN que muestran. Enciende antes el televisor.",
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
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my TV {name}: ": "Sobre mi televisor {name}: ",
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
    "Shown inputs, in order": "Entradas visibles, en orden",
    "Hidden inputs": "Entradas ocultas",
    "Refresh from TV": "Actualizar desde el televisor",
    "Read the TV's apps again": "Volver a leer las apps del televisor",
    "Close": "Cerrar",
    "Shown · {n}": "Visibles · {n}",
    "No input is shown.": "No hay ninguna entrada visible.",
    "Hidden · {n}": "Ocultas · {n}",
    "Every input is shown.": "Todas las entradas están visibles.",
    "The name the TV gives it": "El nombre que le da el televisor",
    "{n} new input from the TV: {names}.": "{n} entrada nueva del televisor: {names}.",
    "{n} new inputs from the TV: {names}.": "{n} entradas nuevas del televisor: {names}.",
    "The TV has no new app.": "El televisor no tiene apps nuevas.",
    "Detect from TV": "Detectar en el televisor",
    "Asking the TV which app is open…": "Preguntando al televisor qué app está abierta…",
    "Found {name}.": "Encontrada: {name}.",
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
    "the TV did not answer: {0}": "el televisor no ha respondido: {0}",
    "the TV refuses connections on port {0}": "el televisor rechaza las conexiones en el puerto {0}",
    "the TV answered HTTP {0}": "el televisor ha respondido HTTP {0}",
    "the TV refused the credentials: pair it again": "el televisor ha rechazado las credenciales: vuelve a emparejarlo",
    "unexpected answer from the TV: {0}": "respuesta inesperada del televisor: {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "el certificado del televisor ({0}) no es el fijado ({1})"
  },
  "pt": {
    "Your Philips Android TVs: control them from here and from the Home app. Each one's options are in its Settings.": "Os seus televisores Philips Android: controle-os daqui e a partir da app Casa. As opções de cada um estão nas suas Definições.",
    "The order of the input wheel in the Home app. Its order, the inputs shown and their names are the TV's Settings (Source Configuration), by these IDs.": "A ordem da roda de entradas na app Casa. Essa ordem, as entradas mostradas e os seus nomes estão nas Definições do televisor (Configuração das fontes), por estes identificadores.",
    "An app the TV does not list goes in the TV's Settings (Custom Apps): open it on the TV, then Detect from TV gives its package name and launch activity.": "Uma app que o televisor não lista vai nas suas Definições (Apps personalizadas): abra-a no televisor e Detetar no televisor dá o nome do pacote e a atividade de arranque.",
    "Your TVs": "Os seus televisores",
    "Add a TV": "Adicionar um televisor",
    "Add accessories finds the Philips TVs on this network and pairs them with the PIN they show. Switch the TV on first.": "Adicionar acessórios encontra os televisores Philips desta rede e emparelha-os com o PIN que mostram. Ligue primeiro o televisor.",
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
    "Show its log": "Mostrar o registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my TV {name}: ": "Sobre o meu televisor {name}: ",
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
    "Shown inputs, in order": "Entradas visíveis, por ordem",
    "Hidden inputs": "Entradas ocultas",
    "Refresh from TV": "Atualizar a partir do televisor",
    "Read the TV's apps again": "Ler novamente as apps do televisor",
    "Close": "Fechar",
    "Shown · {n}": "Visíveis · {n}",
    "No input is shown.": "Nenhuma entrada está visível.",
    "Hidden · {n}": "Ocultas · {n}",
    "Every input is shown.": "Todas as entradas estão visíveis.",
    "The name the TV gives it": "O nome que o televisor lhe dá",
    "{n} new input from the TV: {names}.": "{n} entrada nova do televisor: {names}.",
    "{n} new inputs from the TV: {names}.": "{n} entradas novas do televisor: {names}.",
    "The TV has no new app.": "O televisor não tem apps novas.",
    "Detect from TV": "Detetar no televisor",
    "Asking the TV which app is open…": "A perguntar ao televisor que app está aberta…",
    "Found {name}.": "Encontrada: {name}.",
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
    "the TV did not answer: {0}": "o televisor não respondeu: {0}",
    "the TV refuses connections on port {0}": "o televisor recusa ligações na porta {0}",
    "the TV answered HTTP {0}": "o televisor respondeu HTTP {0}",
    "the TV refused the credentials: pair it again": "o televisor recusou as credenciais: emparelhe-o novamente",
    "unexpected answer from the TV: {0}": "resposta inesperada do televisor: {0}",
    "the TV's certificate ({0}) is not the pinned one ({1})": "o certificado do televisor ({0}) não é o fixado ({1})"
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
  /* The page's own pieces, on the UI's materials: a heading with the plugin's tile, the card to Add accessories,
     and one card per TV with its state and a remote grouped the way a remote is (power, navigation, volume,
     Ambilight). */

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

  /* The inputs: a panel with two columns like the Homebridge plugin's editor, shown (in the wheel's order) and hidden. */
  .column-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 8px; font-size: 0.8125rem; }
  .sources { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .source {
    display: flex; align-items: center; gap: 10px; min-height: 46px; padding: 5px 12px 5px 8px; border-radius: 14px;
    background: var(--control); border: 1px solid var(--edge); box-shadow: inset 0 1px 0 var(--edge-light), var(--shadow-control);
  }
  .pool .source { background: var(--material-thin); box-shadow: none; }
  .pool .source .source-name { color: var(--muted); }
  .kind { flex: none; min-width: 54px; text-align: center; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.03em; padding: 2px 8px; border-radius: 999px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }
  .kind.hdmi { color: #1f6fe0; border-color: rgba(31, 111, 224, 0.3); }
  .kind.tv, .kind.home { color: #7c4ddb; border-color: rgba(124, 77, 219, 0.3); }
  .kind.app { color: var(--ok); border-color: rgba(31, 157, 85, 0.3); }
  .kind.custom { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }
  .source-name { flex: 1; min-width: 0; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .original, .source-id { font-size: 0.75rem; flex: none; max-width: 30%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .empty-list { margin: 0; padding: 14px; border-radius: 14px; border: 1px dashed var(--line); text-align: center; font-size: 0.8125rem; }
  .off-note p { margin: 0; }
  .off-note .explain { margin-top: 4px; }
  .detect { margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--line); }
  .detect .help { margin: 0 0 10px; }
  .status-line { margin: 10px 0 0; min-height: 1.2em; }
  .status-line.error { color: var(--error); }
  .status-line.ok { color: var(--ok); }

  #setup { margin-bottom: 16px; }
  .head-actions { display: flex; gap: 14px; align-items: center; flex-shrink: 0; flex-wrap: wrap; }

  @media (prefers-reduced-motion: reduce) {
    .tv { animation: none; }
  }
  @media (max-width: 640px) {
    .original, .source-id { display: none; }
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
      <p class="muted" data-i18n>Your Philips Android TVs: control them from here and from the Home app. Each one's options are in its Settings.</p>
    </div>
  </div>

  <div id="setup"></div>
  <div class="section-head"><h2 data-i18n>Your TVs</h2></div>
  <div id="tvs" class="tvs"></div>
  <div id="sources" class="card panel hidden"></div>
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
