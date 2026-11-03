// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension ElgatoKeyLightsPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Elgato Key Lights page, after the Homebridge plugin's: the lights the plugin instance knows (refreshed
// every two seconds while the page is visible, redrawn only when something changed), the ones it tried that did not
// answer, and the Excluded ones; the lights Bonjour finds on the network; checking a light at an address. It writes no
// settings (docs/adr/0002-schema-declares-every-setting.md): a light's settings and the plugin's open the Settings pages.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, request, explain, assistant, act, poll, renderKeyed, canonicalMAC } = homeswift;

  const list = $("#lights");
  const kelvin = (mirek) => (mirek ? `${Math.round(1000000 / mirek)} K` : "—");
  // The light's colour on its dot: warm at 2900 K, cool at 7000 K.
  const tint = (mirek) => (mirek ? `hsl(${mirek > 250 ? 35 : 210}, 90%, ${55 + Math.abs(mirek - 250) / 10}%)` : "var(--muted)");

  // MARK: Where settings are edited: the plugin's Settings page, and each light's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const accessoryID = (mac) => `ElgatoKeyLights:${canonicalMAC(mac)}`;
  const lightSettings = (mac) => `${pluginSettings}?accessory=${encodeURIComponent(accessoryID(mac))}`;

  // MARK: The lights

  let lights = [];
  let pending = [];      // lights the plugin tried that are not running: connecting, or they did not answer
  let discovered = [];   // the lights Bonjour announces
  let excluded = [];     // the lights left out of the bridge

  /// Why a light is not running, for its card and Explain.
  function offlineProblem(light) {
    if (light.status === "initializing") return null;
    if (light.error) return `The Elgato light ${light.name} did not answer at ${light.host}:${light.port}: ${light.error}`;
    return `The Elgato light ${light.name} is configured at ${light.host}:${light.port} but has not answered.`;
  }

  /// Tests the connection to a light at its address, the answer in a dialog.
  async function testConnection(light) {
    try {
      const { light: answer } = await request(`probe?host=${encodeURIComponent(light.host)}&port=${light.port}`);
      HomeswiftCommon.showAlert(t("{name} answered in {ms} ms ({model}, firmware {firmware}).", { name: answer.name, ms: answer.milliseconds, model: answer.model, firmware: answer.firmware ?? "?" }));
    } catch (e) {
      HomeswiftCommon.showAlert(e.message);
    }
  }

  const fact = (label, value) => el("div", { class: "fact" }, el("span", { text: label }), el("b", { text: value, title: value }));

  function lightCard(light) {
    if (light.excluded) return excludedCard(light);
    if (light.offline) return offlineCard(light);
    const [state, kind] = !light.reachable ? [t("Not responding"), "away"] : light.on ? [t("On"), "on"] : [t("Off"), "standby"];
    return el("div", { class: "card light" },
      el("div", { class: "server-head" },
        tile("bulb", light.on ? "yellow" : "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: [light.model, light.serial].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts" },
        fact(t("Brightness"), light.on ? `${light.brightness} %` : "—"),
        el("div", { class: "fact" }, el("span", { text: t("Colour") }),
          el("b", { class: "colour" }, el("span", { class: "glow", style: `background:${light.on ? tint(light.temperature) : "var(--line)"}` }), kelvin(light.temperature))),
        fact(t("Firmware"), light.firmware || "—")),
      !light.reachable ? explain({
        error: `The Elgato light ${light.name} does not answer at ${light.host}:${light.port}.`,
        context: "The Homeswift plugin polls the light's HTTP API (/elgato/lights) every second; a light that misses its polls shows as not responding.",
        device: { model: light.model, firmware: light.firmware, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [light.host && `${light.host}:${light.port}`, light.pinned ? t("from config.json") : null, light.mac].filter(Boolean).join(" · ") }),
        // The same menu as the Accessories page's cards, with what this page adds.
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          light.reachable ? { label: t("Identify"), icon: "identify", onSelect: () => request(`identify?mac=${encodeURIComponent(light.mac)}`, { method: "POST" }).catch((e) => HomeswiftCommon.showAlert(e.message)) } : null,
          { label: t("Test connection"), icon: "send", onSelect: () => testConnection(light) },
          { label: t("Settings"), icon: "gear", href: lightSettings(light.mac) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessoryID(light.mac))}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my light {name}: ", { name: light.name })) } : null,
        ])));
  }

  /// A light the plugin tried that is not running, as the Homebridge plugin lists one that did not answer: offline,
  /// with Explain and where its address is set.
  function offlineCard(light) {
    const connecting = light.status === "initializing";
    const [state, kind] = connecting ? [t("Connecting…"), "standby"] : [t("Not responding"), "away"];
    const problem = offlineProblem(light);
    return el("div", { class: "card light is-offline" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.model || "Key Light" })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("p", { class: "muted note", text: connecting ? t("Homeswift is asking the light who it is.") : t("It keeps its place in the Home app and is tried again when Bonjour announces it.") }),
      problem ? explain({
        error: problem,
        context: "The Homeswift plugin connects to a light at start (GET /elgato/accessory-info, /elgato/lights and /elgato/lights/settings, 5 second timeout) and retries when Bonjour announces it.",
        device: { model: light.model, fromConfig: light.pinned },
      }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [`${light.host}:${light.port}`, light.pinned ? t("from config.json") : null, light.mac].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: light.name }), () => [
          { label: t("Test connection"), icon: "send", onSelect: () => testConnection(light) },
          light.pinned ? { label: t("Lights by address"), icon: "gear", href: pluginSettings } : null,
          { label: t("Settings"), icon: "gear", href: lightSettings(light.mac) },
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(accessoryID(light.mac))}` },
        ])));
  }

  /// A light left out of the bridge: its settings bring it back.
  function excludedCard(light) {
    return el("div", { class: "card light is-disabled" },
      el("div", { class: "server-head" },
        tile("bulb", "grey"),
        el("div", { class: "who" }, el("strong", { text: light.name }), el("div", { class: "muted", text: light.mac })),
        el("span", { class: "pill status standby", text: t("Excluded") })),
      el("p", { class: "muted note", text: t("Not on the bridge, nor in the Home app. Its settings bring it back.") }),
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: light.mac }),
        el("a", { class: "button", href: lightSettings(light.mac), actionIcon: "gear", text: t("Settings") })));
  }

  /// The lights the plugin runs, then the ones it tried that are not running (offline), then the Excluded ones.
  function allLights() {
    const running = new Set(lights.map((light) => canonicalMAC(light.mac)));
    const offline = pending.filter((light) => !running.has(canonicalMAC(light.mac))).map((light) => ({ ...light, offline: true }));
    return [...lights, ...offline, ...excluded.map((light) => ({ ...light, excluded: true }))];
  }

  // A card drawn again because its light changed (every brightness step) stays still: only a light new to the
  // page arrives with the material's animation.
  const shown = new Set();
  function card(light) {
    const node = lightCard(light);
    const key = canonicalMAC(light.mac);
    if (shown.has(key)) node.classList.add("redrawn");
    shown.add(key);
    return node;
  }

  async function refresh() {
    try {
      ({ lights, pending = [], discovered = [], excluded = [] } = await request("lights"));
      renderDiscovered();
      const all = allLights();
      if (all.length === 0) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach goes in Lights by address, in the plugin's Settings.") })));
        }
        return;
      }
      renderKeyed(list, all, (light) => canonicalMAC(light.mac), card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: On the network: what Bonjour announces (Homeswift browses all the time; the Homebridge plugin's
  // Discover button scanned for 5 seconds). A light found here is in the Home app once it answered.

  const discoverBox = $("#discovered");

  function discoveredRow(light) {
    const [state, kind] = light.running ? [t("In the Home app"), "on"] : [t("Not answering"), "away"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: light.name }),
        el("div", { class: "muted", text: [light.model, light.address || light.host, light.mac].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      el("a", { class: "button", href: lightSettings(light.mac), actionIcon: "gear", text: t("Settings") }));
  }

  function renderDiscovered() {
    if (discoverBox.classList.contains("hidden")) return;
    const rows = discovered.length
      ? discovered.map(discoveredRow)
      : [el("p", { class: "muted", text: t("No light announces itself over Bonjour right now. A light on another network or behind a container without multicast goes in Lights by address, in the plugin's Settings.") })];
    const key = JSON.stringify(discovered);
    if (discoverBox.dataset.json === key) return;
    discoverBox.dataset.json = key;
    discoverBox.replaceChildren(
      el("p", { class: "muted", text: t("The lights Bonjour finds on the network, kept up to date while Homeswift runs. Each is in the Home app once it answers; its settings name it and set what it does when switched on.") }),
      ...rows);
  }

  $("#discover-toggle").addEventListener("click", () => {
    const open = discoverBox.classList.toggle("hidden") === false;
    $("#discover-toggle").setAttribute("aria-expanded", String(open));
    delete discoverBox.dataset.json;
    renderDiscovered();
  });

  // MARK: Checking a light at its address, for networks Bonjour does not cross: who answers there, and where to keep it.

  const checkBox = $("#check-light");
  const host = el("input", { type: "text", placeholder: "192.168.1.50", inputmode: "decimal", spellcheck: false, "aria-label": t("IP address or host name") });
  const port = el("input", { type: "number", value: 9123, min: 1, max: 65535, "aria-label": t("Port") });
  const checkStatus = el("p", { class: "status-line muted" });
  checkBox.replaceChildren(
    el("p", { class: "muted", text: t("For a light Bonjour does not reach, e.g. on another network or from a container: Homeswift asks it who it is. To keep it, add its address to Lights by address in the plugin's Settings.") }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, checkAddress, checkFailed); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("IP address or host name") }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: t("Port") }), port),
      el("button", { actionIcon: "send", class: "primary", type: "submit", text: t("Check") })),
    checkStatus);
  $("#check-toggle").addEventListener("click", () => {
    const open = checkBox.classList.toggle("hidden") === false;
    $("#check-toggle").setAttribute("aria-expanded", String(open));
    if (open) host.focus();
  });

  function checkFailed(message) {
    checkStatus.className = "status-line error";
    checkStatus.replaceChildren(message, explain({ error: message, context: "Checking an Elgato light by address from the Homeswift plugin page: GET /elgato/accessory-info on the address and port given.", device: { model: "Elgato Key Light" } }));
  }

  async function checkAddress() {
    const address = host.value.trim();
    if (!address) throw new Error(t("Enter the light's IP address or host name."));
    checkStatus.className = "status-line muted";
    checkStatus.textContent = t("Asking {host}:{port}…", { host: address, port: port.value });
    const { light } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    checkStatus.className = "status-line ok";
    checkStatus.replaceChildren(
      t("{name} answered in {ms} ms ({model}, firmware {firmware}).", { name: light.name, ms: light.milliseconds, model: light.model, firmware: light.firmware ?? "?" }), " ",
      light.mac ? t("Its MAC address is {mac}.", { mac: light.mac }) : t("It did not give its MAC address; its Elgato Control Center app shows it."), " ",
      el("a", { href: pluginSettings, text: t("Add it to Lights by address") }));
  }

  // Without an Assistant, a tip on how to get one (Explain on errors), as the Homebridge plugin shows: one sentence
  // to translate, the block's name in bold where the language puts it.
  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  poll(refresh);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Elgato Key Lights page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "Les lampes que connaît cette instance, telles qu'elle les voit en ce moment. Identifier fait clignoter une lampe pour savoir laquelle est laquelle.",
    "Your lights": "Vos lampes",
    "On the network": "Sur le réseau",
    "Not responding": "Ne répond pas",
    "On": "Allumée",
    "Off": "Éteinte",
    "Brightness": "Luminosité",
    "Colour": "Couleur",
    "Firmware": "Firmware",
    "from config.json": "depuis config.json",
    "Actions for {name}": "Actions pour {name}",
    "Identify": "Identifier",
    "Settings": "Réglages",
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my light {name}: ": "À propos de ma lampe {name} : ",
    "Connecting…": "Connexion…",
    "Homeswift is asking the light who it is.": "Homeswift demande à la lampe qui elle est.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Elle garde sa place dans l'app Maison ; Homeswift réessaiera dès que Bonjour l'annoncera.",
    "Test connection": "Tester la connexion",
    "Asking {host}:{port}…": "Interrogation de {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} a répondu en {ms} ms ({model}, firmware {firmware}).",
    "In the Home app": "Dans l'app Maison",
    "Port": "Port",
    "Not answering": "Ne répond pas",
    "IP address or host name": "Adresse IP ou nom d'hôte",
    "Enter the light's IP address or host name.": "Saisissez l'adresse IP ou le nom d'hôte de la lampe.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Astuce : ajoutez un bloc {block} à config.json pour activer l'Assistant, qui explique ici les problèmes de découverte et de connexion.",
    "a host name or IP address is required": "un nom d'hôte ou une adresse IP est requis",
    "the port must be between 1 and 65535": "le port doit être compris entre 1 et 65535",
    "No light answered at {0}:{1}: {2}": "Aucune lampe n'a répondu à {0}:{1} : {2}",
    "no light with that MAC": "aucune lampe avec cette adresse MAC",
    "nothing at {0} {1}": "rien à {0} {1}",
    "Check an address": "Vérifier une adresse",
    "Check": "Vérifier",
    "Lights by address": "Lampes par adresse",
    "Add it to Lights by address": "L'ajouter aux lampes par adresse",
    "Its MAC address is {mac}.": "Son adresse MAC est {mac}.",
    "It did not give its MAC address; its Elgato Control Center app shows it.": "Elle n'a pas donné son adresse MAC ; l'app Elgato Control Center l'affiche.",
    "For a light Bonjour does not reach, e.g. on another network or from a container: Homeswift asks it who it is. To keep it, add its address to Lights by address in the plugin's Settings.": "Pour une lampe que Bonjour ne joint pas, par exemple sur un autre réseau ou depuis un conteneur : Homeswift lui demande qui elle est. Pour la garder, ajoutez son adresse aux lampes par adresse dans les réglages du plugin.",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast goes in Lights by address, in the plugin's Settings.": "Aucune lampe ne s'annonce par Bonjour en ce moment. Une lampe sur un autre réseau ou derrière un conteneur sans multicast va dans les lampes par adresse, dans les réglages du plugin.",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach goes in Lights by address, in the plugin's Settings.": "Aucune lampe trouvée pour l'instant. Les lampes s'annoncent par Bonjour ; une lampe que Bonjour ne joint pas va dans les lampes par adresse, dans les réglages du plugin.",
    "Not on the bridge, nor in the Home app. Its settings bring it back.": "Ni sur le pont, ni dans l'app Maison. Ses réglages la font revenir.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Each is in the Home app once it answers; its settings name it and set what it does when switched on.": "Les lampes que Bonjour trouve sur le réseau, tenues à jour tant que Homeswift tourne. Chacune est dans l'app Maison dès qu'elle répond ; ses réglages la nomment et fixent ce qu'elle fait à l'allumage."
  },
  "es": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "Las luces que conoce esta instancia, tal como las ve ahora. Identificar hace parpadear una luz para que sepas cuál es cuál.",
    "Your lights": "Tus luces",
    "On the network": "En la red",
    "Not responding": "No responde",
    "On": "Encendida",
    "Off": "Apagada",
    "Brightness": "Brillo",
    "Colour": "Color",
    "Firmware": "Firmware",
    "from config.json": "desde config.json",
    "Actions for {name}": "Acciones para {name}",
    "Identify": "Identificar",
    "Settings": "Ajustes",
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my light {name}: ": "Sobre mi luz {name}: ",
    "Connecting…": "Conectando…",
    "Homeswift is asking the light who it is.": "Homeswift le pregunta a la luz quién es.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Mantiene su lugar en la app Casa y se vuelve a intentar cuando Bonjour la anuncia.",
    "Test connection": "Probar la conexión",
    "Asking {host}:{port}…": "Preguntando a {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} ha respondido en {ms} ms ({model}, firmware {firmware}).",
    "In the Home app": "En la app Casa",
    "Port": "Puerto",
    "Not answering": "No responde",
    "IP address or host name": "Dirección IP o nombre de host",
    "Enter the light's IP address or host name.": "Introduce la dirección IP o el nombre de host de la luz.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que aquí explica los problemas de detección y conexión.",
    "a host name or IP address is required": "se necesita un nombre de host o una dirección IP",
    "the port must be between 1 and 65535": "el puerto debe estar entre 1 y 65535",
    "No light answered at {0}:{1}: {2}": "Ninguna luz ha respondido en {0}:{1}: {2}",
    "no light with that MAC": "no hay ninguna luz con esa MAC",
    "nothing at {0} {1}": "no hay nada en {0} {1}",
    "Check an address": "Comprobar una dirección",
    "Check": "Comprobar",
    "Lights by address": "Luces por dirección",
    "Add it to Lights by address": "Añadirla a Luces por dirección",
    "Its MAC address is {mac}.": "Su dirección MAC es {mac}.",
    "It did not give its MAC address; its Elgato Control Center app shows it.": "No ha dado su dirección MAC; la app Elgato Control Center la muestra.",
    "For a light Bonjour does not reach, e.g. on another network or from a container: Homeswift asks it who it is. To keep it, add its address to Lights by address in the plugin's Settings.": "Para una luz que Bonjour no alcanza, por ejemplo en otra red o desde un contenedor: Homeswift le pregunta quién es. Para conservarla, añade su dirección a Luces por dirección en los ajustes del plugin.",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast goes in Lights by address, in the plugin's Settings.": "Ninguna luz se anuncia por Bonjour ahora mismo. Una luz en otra red o tras un contenedor sin multicast va en Luces por dirección, en los ajustes del plugin.",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach goes in Lights by address, in the plugin's Settings.": "Aún no se ha encontrado ninguna luz. Las luces se anuncian por Bonjour; una luz que Bonjour no alcanza va en Luces por dirección, en los ajustes del plugin.",
    "Not on the bridge, nor in the Home app. Its settings bring it back.": "Ni en el puente ni en la app Casa. Sus ajustes la recuperan.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Each is in the Home app once it answers; its settings name it and set what it does when switched on.": "Las luces que Bonjour encuentra en la red, actualizadas mientras Homeswift funciona. Cada una está en la app Casa en cuanto responde; sus ajustes le dan nombre y fijan lo que hace al encenderse."
  },
  "pt": {
    "The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.": "As luzes que esta instância conhece, tal como as vê agora. Identificar faz piscar uma luz para saber qual é qual.",
    "Your lights": "As suas luzes",
    "On the network": "Na rede",
    "Not responding": "Não responde",
    "On": "Ligada",
    "Off": "Desligada",
    "Brightness": "Brilho",
    "Colour": "Cor",
    "Firmware": "Firmware",
    "from config.json": "do config.json",
    "Actions for {name}": "Ações de {name}",
    "Identify": "Identificar",
    "Settings": "Definições",
    "Show its log": "Mostrar o registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my light {name}: ": "Sobre a minha luz {name}: ",
    "Connecting…": "A ligar…",
    "Homeswift is asking the light who it is.": "O Homeswift está a perguntar à luz quem é.",
    "It keeps its place in the Home app and is tried again when Bonjour announces it.": "Mantém o seu lugar na app Casa e é tentada de novo quando o Bonjour a anunciar.",
    "Test connection": "Testar a ligação",
    "Asking {host}:{port}…": "A perguntar a {host}:{port}…",
    "{name} answered in {ms} ms ({model}, firmware {firmware}).": "{name} respondeu em {ms} ms ({model}, firmware {firmware}).",
    "In the Home app": "Na app Casa",
    "Port": "Porta",
    "Not answering": "Não responde",
    "IP address or host name": "Endereço IP ou nome de anfitrião",
    "Enter the light's IP address or host name.": "Introduza o endereço IP ou o nome de anfitrião da luz.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains discovery and connection problems here.": "Sugestão: adicione um bloco {block} ao config.json para ter o Assistente, que aqui explica os problemas de deteção e ligação.",
    "a host name or IP address is required": "é necessário um nome de anfitrião ou um endereço IP",
    "the port must be between 1 and 65535": "a porta tem de estar entre 1 e 65535",
    "No light answered at {0}:{1}: {2}": "Nenhuma luz respondeu em {0}:{1}: {2}",
    "no light with that MAC": "não há nenhuma luz com esse MAC",
    "nothing at {0} {1}": "nada em {0} {1}",
    "Check an address": "Verificar um endereço",
    "Check": "Verificar",
    "Lights by address": "Luzes por endereço",
    "Add it to Lights by address": "Adicioná-la a Luzes por endereço",
    "Its MAC address is {mac}.": "O seu endereço MAC é {mac}.",
    "It did not give its MAC address; its Elgato Control Center app shows it.": "Não deu o seu endereço MAC; a app Elgato Control Center mostra-o.",
    "For a light Bonjour does not reach, e.g. on another network or from a container: Homeswift asks it who it is. To keep it, add its address to Lights by address in the plugin's Settings.": "Para uma luz que o Bonjour não alcança, por exemplo noutra rede ou a partir de um contentor: o Homeswift pergunta-lhe quem é. Para a manter, adicione o seu endereço a Luzes por endereço nas definições do plugin.",
    "No light announces itself over Bonjour right now. A light on another network or behind a container without multicast goes in Lights by address, in the plugin's Settings.": "Nenhuma luz se anuncia por Bonjour neste momento. Uma luz noutra rede ou atrás de um contentor sem multicast vai em Luzes por endereço, nas definições do plugin.",
    "No light found yet. Lights announce themselves over Bonjour; a light Bonjour does not reach goes in Lights by address, in the plugin's Settings.": "Ainda não foi encontrada nenhuma luz. As luzes anunciam-se por Bonjour; uma luz que o Bonjour não alcança vai em Luzes por endereço, nas definições do plugin.",
    "Not on the bridge, nor in the Home app. Its settings bring it back.": "Nem na ponte, nem na app Casa. As suas definições trazem-na de volta.",
    "The lights Bonjour finds on the network, kept up to date while Homeswift runs. Each is in the Home app once it answers; its settings name it and set what it does when switched on.": "As luzes que o Bonjour encontra na rede, mantidas atualizadas enquanto o Homeswift corre. Cada uma está na app Casa assim que responde; as suas definições dão-lhe nome e definem o que faz ao ligar."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Elgato Key Lights</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* A card per light on the UI's materials: its state as facts, where it is, and Identify. */
  .light { display: grid; gap: 14px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
  .light .actions { margin-top: 0; }
  .light.redrawn { animation: none; }
  .glow { width: 10px; height: 10px; border-radius: 50%; flex: none; box-shadow: 0 0 0 3px var(--material-thin); }
  .fact b.colour { display: flex; align-items: center; gap: 8px; }
  .light.is-disabled, .light.is-offline { opacity: 0.7; }
  .section-head .actions { margin-top: 0; }
  .found { display: flex; align-items: center; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .found .who { flex: 1; min-width: 180px; }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  .found .button { margin-left: auto; }
  .add-box { margin-bottom: 14px; animation: materialize var(--normal) var(--ease-out); }
  .add-box > p:first-child { margin-top: 0; font-size: 0.875rem; }
  .add-form { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; }
  .add-form .field { flex: 1; min-width: 200px; margin: 0; }
  .add-form .field.port { flex: 0 0 110px; min-width: 0; }
  @media (prefers-reduced-motion: reduce) { .light, .add-box { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-yellow" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2V16h5v-.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z"/></svg></span>
    <div class="who">
      <h1>Elgato Key Lights</h1>
      <p class="muted" data-i18n>The lights this instance knows, as it sees them right now. Identify flashes a light so you can tell which is which.</p>
    </div>
  </div>
  <div class="section-head"><h2 data-i18n>Your lights</h2><div class="actions"><button id="discover-toggle" aria-expanded="false" aria-controls="discovered" data-i18n data-action-icon="search">On the network</button><button id="check-toggle" aria-expanded="false" aria-controls="check-light" data-i18n data-action-icon="send">Check an address</button></div></div>
  <div id="discovered" class="card add-box hidden"></div>
  <div id="check-light" class="card add-box hidden"></div>
  <div id="lights" class="grid"></div>
  <p id="assistant-hint" class="hint hidden">Tip: add a <strong>HomeswiftAiKit</strong> block to config.json to get the Assistant, which explains discovery and connection problems here.</p>
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
