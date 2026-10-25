// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension WingmanPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Wingman page: the paired Wingmen (refreshed every two seconds while the page is visible, a card redrawn only
// when it changed), the Wingmen Bonjour finds, one added by its address, and pairing: the certificate this bridge
// sees, to compare with Wingman's Bridges tab, then the six-digit code its menu shows. Pairing writes the Wingman's
// entry in this instance's block, and the plugin reloads with it.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, act, updateDevices, poll, renderKeyed } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");
  const discoverBox = $("#discovered");
  const addBox = $("#add-wingman");

  /// AB:CD:… for people: the first `bytes` bytes, as Wingman's window shows them.
  const formatFingerprint = (hex, bytes) => (hex || "").replace(/[^0-9a-f]/gi, "").toUpperCase().slice(0, bytes * 2).replace(/(..)(?!$)/g, "$1:");

  // MARK: config.json: the block's `devices`, one entry per Wingman by its id (plugin.js keeps the list).

  const putEntry = (entry) => updateDevices((devices) => {
    const index = devices.findIndex((d) => d.id === entry.id);
    if (index >= 0) devices[index] = { ...devices[index], ...entry }; else devices.push(entry);
  });

  const removeEntry = (id) => updateDevices((devices) => {
    const index = devices.findIndex((d) => d.id === id);
    if (index >= 0) devices.splice(index, 1);
  });

  // MARK: The paired Wingmen

  function stateOf(wingman) {
    switch (wingman.state) {
      case "connected": return [t("Connected"), "on"];
      case "connecting": return [t("Connecting…"), "standby"];
      case "unpaired": return [t("Pair again"), "away"];
      default: return [t("Not reachable"), "away"];
    }
  }

  function wingmanCard(wingman) {
    const [state, kind] = stateOf(wingman);
    const homes = (wingman.homes || []).join(", ");
    const updated = wingman.lastContact ? t("updated {when}", { when: ago(wingman.lastContact) }) : null;
    const quiet = (wingman.notResponding ?? 0) > 0;
    return el("div", { class: "card wingman" },
      el("div", { class: "server-head" },
        tile("bridge", wingman.state === "connected" ? "blue" : "grey"),
        el("div", { class: "who" }, el("strong", { text: wingman.name }), el("div", { class: "muted", text: [homes || t("Apple Home"), updated].filter(Boolean).join(" · ") })),
        el("span", { class: `pill status ${kind}`, text: state })),
      el("div", { class: "facts three" },
        fact(t("Accessories"), String(wingman.accessories ?? 0)),
        el("div", { class: `fact${quiet ? " warn" : ""}` }, el("span", { text: t("Not responding") }), el("b", { text: String(wingman.notResponding ?? 0) })),
        el("div", { class: "fact", title: t("Homeswift's own accessories, and those left out in the settings") }, el("span", { text: t("Left out") }), el("b", { text: String(wingman.leftOut ?? 0) }))),
      wingman.error ? el("p", { class: "error note", text: wingman.error }) : null,
      wingman.error ? explain({
        error: `Wingman ${wingman.name} at ${wingman.host}:${wingman.port}: ${wingman.error}`,
        context: "The Homeswift Wingman plugin reads GET /homes from Wingman over TLS (certificate pinned at pairing) and follows GET /events?since=&wait=25.",
        device: { state: wingman.state, pinned: wingman.pinned },
      }) : null,
      wingman.state === "unpaired" ? el("p", { class: "muted note", text: t("Wingman no longer knows this bridge. Find it on the network and pair it again.") }) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [wingman.host && `${wingman.host}:${wingman.port}`, wingman.pinned ? t("Certificate pinned") : null].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: wingman.name }), () => [
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(homeswift.platform)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Wingman {name}: ", { name: wingman.name })) } : null,
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => forget(wingman) },
        ])));
  }

  async function forget(wingman) {
    if (!confirm(t("Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.", { name: wingman.name }))) return;
    await removeEntry(wingman.id);
    setTimeout(refresh, 600);
  }

  const shown = new Set();
  function card(wingman) {
    const node = wingmanCard(wingman);
    if (shown.has(wingman.id)) node.classList.add("redrawn");
    shown.add(wingman.id);
    return node;
  }

  async function refresh() {
    try {
      const { wingmen } = await request("wingmen");
      if (!wingmen.length) {
        if (!list.querySelector(".empty")) {
          list.replaceChildren(el("div", { class: "card empty" },
            el("p", { class: "muted", text: t("No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then find it on the network here.") })));
        }
        if (discoverBox.classList.contains("hidden") && !discoveredOnce) openDiscovered();
        return;
      }
      renderKeyed(list, wingmen, (wingman) => wingman.id, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: On the network

  let discoveredOnce = false;

  function foundRow(wingman) {
    const [state, kind] = wingman.error ? [t("Not answering"), "away"] : wingman.paired ? [t("Paired"), "on"] : wingman.pairing ? [t("Pairing open"), "on"] : [t("Not paired"), "standby"];
    return el("div", { class: "found" },
      el("div", { class: "who" }, el("strong", { text: wingman.name }),
        el("div", { class: "muted", text: [`${wingman.host}:${wingman.port}`, wingman.version && t("version {version}", { version: wingman.version })].filter(Boolean).join(" · ") })),
      el("span", { class: `pill status ${kind}`, text: state }),
      wingman.error || !wingman.fingerprint ? null
        : el("button", { class: wingman.paired ? "" : "primary", text: wingman.paired ? t("Pair again") : t("Pair"), onclick: (event) => openPairing(wingman, event.currentTarget.closest(".found")) }));
  }

  async function renderDiscovered() {
    discoveredOnce = true;
    discoverBox.replaceChildren(el("p", { class: "muted", text: t("Looking for Wingman on the network…") }));
    try {
      const { wingmen } = await request("discover");
      discoverBox.replaceChildren(
        el("p", { class: "muted", text: t("The Wingman apps Bonjour finds on this network. Pairing needs the Mac at hand: Wingman shows the code.") }),
        ...(wingmen.length ? wingmen.map(foundRow)
          : [el("p", { class: "muted", text: t("No Wingman announces itself. Is Homeswift Wingman running, with Advertise over Bonjour on? Across networks or from a container, add it by its address.") })]),
        el("div", { class: "actions" }, el("button", { text: t("Look again"), onclick: (event) => act(event.currentTarget, renderDiscovered) })));
    } catch (e) {
      discoverBox.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  function openDiscovered() {
    discoverBox.classList.remove("hidden");
    $("#discover-toggle").setAttribute("aria-expanded", "true");
    renderDiscovered();
  }

  $("#discover-toggle").addEventListener("click", () => {
    if (discoverBox.classList.contains("hidden")) openDiscovered();
    else { discoverBox.classList.add("hidden"); $("#discover-toggle").setAttribute("aria-expanded", "false"); }
  });

  // MARK: Adding by address, for networks Bonjour does not cross

  const host = el("input", { type: "text", placeholder: "192.168.1.20", inputmode: "decimal", spellcheck: false, "aria-label": t("IP address or host name") });
  const port = el("input", { type: "number", value: 8619, min: 1, max: 65535, "aria-label": t("Port") });
  const addStatus = el("p", { class: "status-line muted" });
  addBox.replaceChildren(
    el("p", { class: "muted", text: t("For a Wingman Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then you pair it.") }),
    el("form", { class: "add-form", onsubmit: (event) => { event.preventDefault(); act(event.submitter, probe, (message) => { addStatus.className = "status-line error"; addStatus.textContent = message; }); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("IP address or host name") }), host),
      el("label", { class: "field port" }, el("span", { class: "field-title", text: t("Port") }), port),
      el("button", { class: "primary", type: "submit", text: t("Find") })),
    addStatus);
  $("#add-toggle").addEventListener("click", () => {
    const open = addBox.classList.toggle("hidden") === false;
    $("#add-toggle").setAttribute("aria-expanded", String(open));
    if (open) host.focus();
  });

  async function probe() {
    const address = host.value.trim();
    if (!address) throw new Error(t("Enter the Mac's IP address or host name."));
    addStatus.className = "status-line muted";
    addStatus.textContent = t("Asking {host}:{port}…", { host: address, port: port.value });
    const { wingman } = await request(`probe?host=${encodeURIComponent(address)}&port=${encodeURIComponent(port.value)}`);
    addStatus.textContent = "";
    openPairing(wingman, addStatus);
  }

  // MARK: Pairing: compare the certificate, then the code. The panel opens under the row whose Pair was pressed (or
  // the address form), so it reads as that Wingman's; one at a time.

  let pairing = null;

  function closePairing(panel) {
    panel.remove();
    if (pairing === panel) pairing = null;
  }

  function openPairing(wingman, anchor) {
    pairing?.remove();
    const code = el("input", { class: "code-input", type: "text", inputmode: "numeric", autocomplete: "one-time-code", enterkeyhint: "done", maxLength: 7, placeholder: "000 000", "aria-label": t("Pairing code") });
    const label = el("input", { type: "text", value: wingman.name, maxLength: 64, "aria-label": t("Name") });
    const status = el("p", { class: "status-line muted", "aria-live": "polite" });
    const submit = el("button", { class: "primary", type: "submit", text: t("Pair") });
    const panel = el("div", { class: "pair" });
    const close = () => closePairing(panel);
    const report = (message) => { status.className = "status-line error"; status.textContent = message; code.select(); };
    const form = el("form", { class: "pair-form", onsubmit: (event) => { event.preventDefault(); act(submit, () => pair(wingman, code.value, label.value, panel), report); } },
      el("label", { class: "field" }, el("span", { class: "field-title", text: t("Name") }), label),
      el("div", { class: "code-row" },
        el("label", { class: "field" }, el("span", { class: "field-title", text: t("Pairing code") }), code),
        submit,
        el("button", { type: "button", text: t("Cancel"), onclick: close })));
    // The code as Wingman shows it, 482 913; the sixth digit pairs, as a one-time code does on a phone.
    code.addEventListener("input", () => {
      const digits = code.value.replace(/\D/g, "").slice(0, 6);
      code.value = digits.length > 3 ? `${digits.slice(0, 3)} ${digits.slice(3)}` : digits;
      status.textContent = "";
      if (digits.length === 6 && !submit.disabled) form.requestSubmit(submit);
    });
    panel.replaceChildren(
      el("h3", { text: t("Pair {name}", { name: wingman.name }) }),
      el("ol", { class: "muted pair-steps" },
        el("li", { text: t("In Wingman's menu, choose Pair a Homeswift Bridge. It shows a code for ten minutes.") }),
        el("li", { text: t("In Wingman's window, Bridges tab, check that the certificate starts as below.") }),
        el("li", { text: t("Type the code here.") })),
      el("div", { class: "fingerprint" },
        el("span", { class: "muted", text: t("Certificate SHA-256, as this bridge sees it") }),
        el("code", { text: `${formatFingerprint(wingman.fingerprint, 6)}…` })),
      form, status);
    anchor.after(panel);
    pairing = panel;
    panel.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "nearest" });
    code.focus();
  }

  async function pair(wingman, code, name, panel) {
    const digits = code.replace(/\D/g, "");
    if (digits.length !== 6) throw new Error(t("The code has six digits."));
    const { device } = await request("pair", { method: "POST", body: { host: wingman.host, port: wingman.port, code: digits, fingerprint: wingman.fingerprint, name: name.trim() } });
    await putEntry(device);
    panel.replaceChildren(el("p", { class: "status-line ok", text: t("Paired with {name}. Its Apple Home accessories appear on the Accessories page in a moment.", { name: device.name || wingman.name }) }));
    setTimeout(() => { closePairing(panel); if (!discoverBox.classList.contains("hidden")) renderDiscovered(); }, 4000);
    setTimeout(refresh, 800);
  }

  const [tipBefore, tipAfter = ""] = t("Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.").split("{block}");
  $("#assistant-hint").replaceChildren(tipBefore, el("strong", { text: "HomeswiftAiKit" }), tipAfter);
  assistant().then((state) => $("#assistant-hint").classList.toggle("hidden", Boolean(state.enabled)));

  poll(refresh);
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Wingman page in French, Spanish and Portuguese (docs/translations.md).
HomeswiftI18n.add({
  "fr": {
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, moods, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Les accessoires de l'app Maison dans Homeswift, grâce à Homeswift Wingman sur un Mac. Ils rejoignent la page Accessoires, les ambiances, les scènes et l'Assistant, et restent hors de HomeKit, qui les a déjà.",
    "Your Wingmen": "Vos Wingman",
    "On the network": "Sur le réseau",
    "Add by address": "Ajouter par adresse",
    "Connected": "Connecté",
    "Connecting…": "Connexion…",
    "Pair again": "Jumeler à nouveau",
    "Not reachable": "Injoignable",
    "Apple Home": "l'app Maison",
    "updated {when}": "mis à jour {when}",
    "Accessories": "Accessoires",
    "Not responding": "Ne répondent pas",
    "Left out": "Laissés de côté",
    "Wingman no longer knows this bridge. Find it on the network and pair it again.": "Wingman ne connaît plus ce pont. Trouvez-le sur le réseau et jumelez-le à nouveau.",
    "Homeswift's own accessories, and those left out in the settings": "Les accessoires de Homeswift, et ceux laissés de côté dans les réglages",
    "Certificate pinned": "Certificat épinglé",
    "Actions for {name}": "Actions pour {name}",
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my Wingman {name}: ": "À propos de mon Wingman {name} : ",
    "Remove": "Supprimer",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "Supprimer {name} ? Ses accessoires de l'app Maison quittent Homeswift. Retirez aussi ce pont des ponts jumelés de Wingman.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then find it on the network here.": "Aucun Wingman jumelé pour l'instant. Ouvrez Homeswift Wingman sur un Mac de la maison, puis trouvez-le sur le réseau ici.",
    "Not answering": "Ne répond pas",
    "Paired": "Jumelé",
    "Pairing open": "Jumelage ouvert",
    "Not paired": "Non jumelé",
    "version {version}": "version {version}",
    "Pair": "Jumeler",
    "Looking for Wingman on the network…": "Recherche de Wingman sur le réseau…",
    "The Wingman apps Bonjour finds on this network. Pairing needs the Mac at hand: Wingman shows the code.": "Les apps Wingman que Bonjour trouve sur ce réseau. Le jumelage demande d'avoir le Mac sous la main : Wingman affiche le code.",
    "No Wingman announces itself. Is Homeswift Wingman running, with Advertise over Bonjour on? Across networks or from a container, add it by its address.": "Aucun Wingman ne s'annonce. Homeswift Wingman est-il ouvert, avec l'annonce Bonjour activée ? Depuis un autre réseau ou un conteneur, ajoutez-le par son adresse.",
    "Look again": "Chercher à nouveau",
    "IP address or host name": "Adresse IP ou nom d'hôte",
    "Port": "Port",
    "For a Wingman Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then you pair it.": "Pour un Wingman que Bonjour n'atteint pas, par exemple sur un autre réseau ou depuis un conteneur. Homeswift lui demande qui il est, puis vous le jumelez.",
    "Find": "Trouver",
    "Enter the Mac's IP address or host name.": "Saisissez l'adresse IP ou le nom d'hôte du Mac.",
    "Asking {host}:{port}…": "Interrogation de {host}:{port}…",
    "Pairing code": "Code de jumelage",
    "Name": "Nom",
    "Pair {name}": "Jumeler {name}",
    "In Wingman's menu, choose Pair a Homeswift Bridge. It shows a code for ten minutes.": "Dans le menu de Wingman, choisissez Pair a Homeswift Bridge. Il affiche un code pendant dix minutes.",
    "In Wingman's window, Bridges tab, check that the certificate starts as below.": "Dans la fenêtre de Wingman, onglet Bridges, vérifiez que le certificat commence comme ci-dessous.",
    "Type the code here.": "Saisissez le code ici.",
    "Certificate SHA-256, as this bridge sees it": "Certificat SHA-256, tel que ce pont le voit",
    "Cancel": "Annuler",
    "The code has six digits.": "Le code a six chiffres.",
    "Paired with {name}. Its Apple Home accessories appear on the Accessories page in a moment.": "Jumelé avec {name}. Ses accessoires de l'app Maison apparaissent dans un instant sur la page Accessoires.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Astuce : ajoutez un bloc {block} à config.json pour avoir l'Assistant, qui explique ici les problèmes de connexion.",
  },
  "es": {
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, moods, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Los accesorios de la app Casa en Homeswift, a través de Homeswift Wingman en un Mac. Se suman a la página Accesorios, los ambientes, las escenas y el Asistente, y quedan fuera de HomeKit, que ya los tiene.",
    "Your Wingmen": "Tus Wingman",
    "On the network": "En la red",
    "Add by address": "Añadir por dirección",
    "Connected": "Conectado",
    "Connecting…": "Conectando…",
    "Pair again": "Volver a emparejar",
    "Not reachable": "Inaccesible",
    "Apple Home": "la app Casa",
    "updated {when}": "actualizado {when}",
    "Accessories": "Accesorios",
    "Not responding": "No responden",
    "Left out": "Excluidos",
    "Wingman no longer knows this bridge. Find it on the network and pair it again.": "Wingman ya no conoce este puente. Búscalo en la red y vuelve a emparejarlo.",
    "Homeswift's own accessories, and those left out in the settings": "Los accesorios de Homeswift, y los excluidos en los ajustes",
    "Certificate pinned": "Certificado fijado",
    "Actions for {name}": "Acciones para {name}",
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my Wingman {name}: ": "Sobre mi Wingman {name}: ",
    "Remove": "Eliminar",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "¿Eliminar {name}? Sus accesorios de la app Casa salen de Homeswift. Quita también este puente de los puentes emparejados de Wingman.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then find it on the network here.": "Aún no hay ningún Wingman emparejado. Abre Homeswift Wingman en un Mac de la casa y búscalo aquí en la red.",
    "Not answering": "No responde",
    "Paired": "Emparejado",
    "Pairing open": "Emparejamiento abierto",
    "Not paired": "Sin emparejar",
    "version {version}": "versión {version}",
    "Pair": "Emparejar",
    "Looking for Wingman on the network…": "Buscando Wingman en la red…",
    "The Wingman apps Bonjour finds on this network. Pairing needs the Mac at hand: Wingman shows the code.": "Las apps Wingman que Bonjour encuentra en esta red. Para emparejar hace falta tener el Mac a mano: Wingman muestra el código.",
    "No Wingman announces itself. Is Homeswift Wingman running, with Advertise over Bonjour on? Across networks or from a container, add it by its address.": "Ningún Wingman se anuncia. ¿Está abierto Homeswift Wingman, con el anuncio por Bonjour activado? Desde otra red o un contenedor, añádelo por su dirección.",
    "Look again": "Buscar de nuevo",
    "IP address or host name": "Dirección IP o nombre de host",
    "Port": "Puerto",
    "For a Wingman Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then you pair it.": "Para un Wingman que Bonjour no alcanza, por ejemplo en otra red o desde un contenedor. Homeswift le pregunta quién es y luego lo emparejas.",
    "Find": "Buscar",
    "Enter the Mac's IP address or host name.": "Introduce la dirección IP o el nombre de host del Mac.",
    "Asking {host}:{port}…": "Preguntando a {host}:{port}…",
    "Pairing code": "Código de emparejamiento",
    "Name": "Nombre",
    "Pair {name}": "Emparejar {name}",
    "In Wingman's menu, choose Pair a Homeswift Bridge. It shows a code for ten minutes.": "En el menú de Wingman, elige Pair a Homeswift Bridge. Muestra un código durante diez minutos.",
    "In Wingman's window, Bridges tab, check that the certificate starts as below.": "En la ventana de Wingman, pestaña Bridges, comprueba que el certificado empieza como abajo.",
    "Type the code here.": "Escribe el código aquí.",
    "Certificate SHA-256, as this bridge sees it": "Certificado SHA-256, tal como lo ve este puente",
    "Cancel": "Cancelar",
    "The code has six digits.": "El código tiene seis cifras.",
    "Paired with {name}. Its Apple Home accessories appear on the Accessories page in a moment.": "Emparejado con {name}. Sus accesorios de la app Casa aparecen en un momento en la página Accesorios.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que explica aquí los problemas de conexión.",
  },
  "pt": {
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, moods, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Os acessórios da app Casa no Homeswift, através do Homeswift Wingman num Mac. Juntam-se à página Acessórios, aos ambientes, às cenas e ao Assistente, e ficam fora do HomeKit, que já os tem.",
    "Your Wingmen": "Os seus Wingman",
    "On the network": "Na rede",
    "Add by address": "Adicionar por endereço",
    "Connected": "Ligado",
    "Connecting…": "A ligar…",
    "Pair again": "Emparelhar de novo",
    "Not reachable": "Inacessível",
    "Apple Home": "a app Casa",
    "updated {when}": "atualizado {when}",
    "Accessories": "Acessórios",
    "Not responding": "Não respondem",
    "Left out": "Excluídos",
    "Wingman no longer knows this bridge. Find it on the network and pair it again.": "O Wingman já não conhece esta ponte. Encontre-o na rede e emparelhe-o de novo.",
    "Homeswift's own accessories, and those left out in the settings": "Os acessórios do Homeswift, e os excluídos nas definições",
    "Certificate pinned": "Certificado fixado",
    "Actions for {name}": "Ações para {name}",
    "Show its log": "Ver o seu registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my Wingman {name}: ": "Sobre o meu Wingman {name}: ",
    "Remove": "Remover",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "Remover {name}? Os seus acessórios da app Casa saem do Homeswift. Retire também esta ponte das pontes emparelhadas do Wingman.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then find it on the network here.": "Ainda não há nenhum Wingman emparelhado. Abra o Homeswift Wingman num Mac da casa e encontre-o aqui na rede.",
    "Not answering": "Não responde",
    "Paired": "Emparelhado",
    "Pairing open": "Emparelhamento aberto",
    "Not paired": "Não emparelhado",
    "version {version}": "versão {version}",
    "Pair": "Emparelhar",
    "Looking for Wingman on the network…": "A procurar o Wingman na rede…",
    "The Wingman apps Bonjour finds on this network. Pairing needs the Mac at hand: Wingman shows the code.": "As apps Wingman que o Bonjour encontra nesta rede. Para emparelhar é preciso ter o Mac à mão: o Wingman mostra o código.",
    "No Wingman announces itself. Is Homeswift Wingman running, with Advertise over Bonjour on? Across networks or from a container, add it by its address.": "Nenhum Wingman se anuncia. O Homeswift Wingman está aberto, com o anúncio por Bonjour ativado? A partir de outra rede ou de um contentor, adicione-o pelo endereço.",
    "Look again": "Procurar de novo",
    "IP address or host name": "Endereço IP ou nome de anfitrião",
    "Port": "Porta",
    "For a Wingman Bonjour does not reach, e.g. on another network or from a container. Homeswift asks it who it is, then you pair it.": "Para um Wingman que o Bonjour não alcança, por exemplo noutra rede ou a partir de um contentor. O Homeswift pergunta-lhe quem é e depois emparelha-o.",
    "Find": "Procurar",
    "Enter the Mac's IP address or host name.": "Introduza o endereço IP ou o nome de anfitrião do Mac.",
    "Asking {host}:{port}…": "A perguntar a {host}:{port}…",
    "Pairing code": "Código de emparelhamento",
    "Name": "Nome",
    "Pair {name}": "Emparelhar {name}",
    "In Wingman's menu, choose Pair a Homeswift Bridge. It shows a code for ten minutes.": "No menu do Wingman, escolha Pair a Homeswift Bridge. Mostra um código durante dez minutos.",
    "In Wingman's window, Bridges tab, check that the certificate starts as below.": "Na janela do Wingman, separador Bridges, confirme que o certificado começa como abaixo.",
    "Type the code here.": "Escreva o código aqui.",
    "Certificate SHA-256, as this bridge sees it": "Certificado SHA-256, tal como esta ponte o vê",
    "Cancel": "Cancelar",
    "The code has six digits.": "O código tem seis algarismos.",
    "Paired with {name}. Its Apple Home accessories appear on the Accessories page in a moment.": "Emparelhado com {name}. Os seus acessórios da app Casa aparecem dentro de momentos na página Acessórios.",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Dica: adicione um bloco {block} ao config.json para ter o Assistente, que explica aqui os problemas de ligação.",
  },
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wingman</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* A card per paired Wingman on the UI's materials (its state as facts), the Wingmen on the network, and the
     pairing panel: the certificate to compare, then the code. */
  .wingman { display: grid; gap: 14px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
  .wingman.redrawn { animation: none; }
  .wingman .note { margin: 0; }
  .section-head .actions { margin-top: 0; }
  .found { display: flex; align-items: center; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .found:first-of-type { border-top: 0; }
  .found .who { flex: 1; min-width: 180px; }
  .add-box { margin-bottom: 14px; animation: materialize var(--normal) var(--ease-out); }
  .add-box > p:first-child { margin-top: 0; font-size: 0.875rem; }
  .add-form { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; }
  .add-form .field { flex: 1; min-width: 200px; margin: 0; }
  .add-form .field.port { flex: 0 0 110px; min-width: 0; }
  /* The pairing panel, under its row: a tinted inset of the list's card, arriving as a material. */
  .pair {
    display: grid; gap: 14px; margin: 4px 0 10px; padding: 16px; border-radius: 18px;
    background: var(--material-thin); border: 1px solid var(--line); animation: materialize var(--normal) var(--ease-out);
  }
  .pair h3 { margin: 0; font-size: 1rem; letter-spacing: -0.01em; }
  .pair .pair-steps { margin: 0; padding-left: 1.25em; font-size: 0.875rem; line-height: 1.55; }
  .pair .status-line:empty { display: none; }
  .facts.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .fact.warn b { color: var(--warn); }
  .fingerprint { margin: 0; padding: 12px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); display: grid; gap: 4px; }
  .fingerprint code { font-size: 1.0625rem; font-weight: 600; letter-spacing: 0.02em; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
  .pair-form { display: grid; gap: 12px; }
  .pair-form .field { margin: 0; max-width: 360px; }
  .code-row { display: flex; gap: 12px; align-items: flex-end; flex-wrap: wrap; }
  .code-row .field { flex: 0 1 240px; }
  .code-input { font-size: 1.75rem; font-weight: 600; letter-spacing: 0.3em; text-align: center; font-variant-numeric: tabular-nums; max-width: 240px; }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  @media (pointer: coarse) { .add-form input, .pair-form input { font-size: 16px; } .pair-form .code-input { font-size: 1.75rem; } }
  @media (prefers-reduced-motion: reduce) { .wingman, .add-box, .pair { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-orange" aria-hidden="true"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 320"><g fill="currentColor" stroke="none"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/><g transform="translate(500 0) scale(-1 1)"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/></g></g><path d="M136 220L250 104L364 220M153 205V305H347V205" fill="none" stroke="currentColor" stroke-width="29" stroke-linecap="round" stroke-linejoin="round"/></svg></span>
    <div class="who">
      <h1>Wingman</h1>
      <p class="muted" data-i18n>The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, moods, scenes and the Assistant, and stay out of HomeKit, which has them already.</p>
    </div>
  </div>
  <div class="section-head"><h2 data-i18n>Your Wingmen</h2><div class="actions"><button id="discover-toggle" aria-expanded="false" aria-controls="discovered" data-i18n>On the network</button><button id="add-toggle" aria-expanded="false" aria-controls="add-wingman" data-i18n>Add by address</button></div></div>
  <div id="discovered" class="card add-box hidden"></div>
  <div id="add-wingman" class="card add-box hidden"></div>
  <div id="wingmen" class="grid"></div>
  <p id="assistant-hint" class="hint hidden"></p>
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
