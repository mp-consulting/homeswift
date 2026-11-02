// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension WingmanPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Wingman page: the paired Wingmen, refreshed every two seconds while the page is visible, a card redrawn only
// when it changed. A Wingman is found and paired on Add accessories (Setup: the certificate to compare, then the
// six-digit code its menu shows): the page leads there.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, api, platform, name: instance, updateBlock, poll, renderKeyed, setupCard, setupAddress } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");

  // MARK: config.json: a Wingman paired before Setup has an entry in the block's `devices`, by its id; one Setup paired
  // has its Accessory Settings (`_accessories`, by its id), and leaves as Add accessories excludes it.

  async function removeEntry(id) {
    let listed = false;
    await updateBlock((block) => {
      const devices = block.devices || [];
      listed = devices.some((d) => d.id === id);
      if (!listed) return;
      block.devices = devices.filter((d) => d.id !== id);
      if (!block.devices.length) delete block.devices;
    });
    if (!listed) await api("/api/setup/exclude", { method: "POST", body: { platform, name: instance, deviceID: id, excluded: true } });
  }

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
      wingman.state === "unpaired" ? el("p", { class: "muted note", text: t("Wingman no longer knows this bridge. Pair it again on Add accessories.") }) : null,
      wingman.state === "unpaired" ? el("div", { class: "actions" }, el("a", { class: "button primary", href: setupAddress(), actionIcon: "pair", text: t("Pair again") })) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: [wingman.host && `${wingman.host}:${wingman.port}`, wingman.pinned ? t("Certificate pinned") : null].filter(Boolean).join(" · ") }),
        HomeswiftCommon.menuButton(t("Actions for {name}", { name: wingman.name }), () => [
          { label: t("Show its log"), icon: "logs", href: `/logs/${encodeURIComponent(homeswift.platform)}` },
          window.HomeswiftChat?.available() ? { label: t("Ask the Assistant"), icon: HomeswiftCommon.sparkle(), onSelect: () => HomeswiftChat.ask(t("About my Wingman {name}: ", { name: wingman.name })) } : null,
          { label: t("Remove"), icon: "trash", danger: true, onSelect: () => forget(wingman) },
        ])));
  }

  async function forget(wingman) {
    if (!await HomeswiftCommon.confirmDialog(t("Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.", { name: wingman.name }))) return;
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
            el("p", { class: "muted", text: t("No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then pair it on Add accessories.") })));
        }
        return;
      }
      renderKeyed(list, wingmen, (wingman) => wingman.id, card);
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
    }
  }

  // MARK: Pairing a Wingman: Add accessories finds it (or takes the address in the plugin's settings) and pairs it.

  $("#setup").replaceChildren(setupCard({
    title: t("Pair a Wingman"),
    text: t("Add accessories finds Homeswift Wingman on this network: compare its certificate, then type the code its menu shows. For a Mac Bonjour does not reach, add its address to this plugin's settings first."),
    glyph: "pair", tone: "orange", start: false,
  }));

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
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Les accessoires de l'app Maison dans Homeswift, grâce à Homeswift Wingman sur un Mac. Ils rejoignent la page Accessoires, les scènes et l'Assistant, et restent hors de HomeKit, qui les a déjà.",
    "Your Wingmen": "Vos Wingman",
    "Wingman no longer knows this bridge. Pair it again on Add accessories.": "Wingman ne connaît plus ce pont. Jumelez-le à nouveau dans Ajouter des accessoires.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then pair it on Add accessories.": "Aucun Wingman jumelé pour l'instant. Ouvrez Homeswift Wingman sur un Mac de la maison, puis jumelez-le dans Ajouter des accessoires.",
    "Pair a Wingman": "Jumeler un Wingman",
    "Add accessories finds Homeswift Wingman on this network: compare its certificate, then type the code its menu shows. For a Mac Bonjour does not reach, add its address to this plugin's settings first.": "Ajouter des accessoires trouve Homeswift Wingman sur ce réseau : comparez son certificat, puis saisissez le code qu'affiche son menu. Pour un Mac que Bonjour n'atteint pas, ajoutez d'abord son adresse aux réglages de ce plugin.",
    "Connected": "Connecté",
    "Connecting…": "Connexion…",
    "Pair again": "Jumeler à nouveau",
    "Not reachable": "Injoignable",
    "Apple Home": "l'app Maison",
    "updated {when}": "mis à jour {when}",
    "Accessories": "Accessoires",
    "Not responding": "Ne répondent pas",
    "Left out": "Laissés de côté",
    "Homeswift's own accessories, and those left out in the settings": "Les accessoires de Homeswift, et ceux laissés de côté dans les réglages",
    "Certificate pinned": "Certificat épinglé",
    "Actions for {name}": "Actions pour {name}",
    "Show its log": "Afficher son journal",
    "Ask the Assistant": "Demander à l'Assistant",
    "About my Wingman {name}: ": "À propos de mon Wingman {name} : ",
    "Remove": "Supprimer",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "Supprimer {name} ? Ses accessoires de l'app Maison quittent Homeswift. Retirez aussi ce pont des ponts jumelés de Wingman.",
    "Paired": "Jumelé",
    "Pair": "Jumeler",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Astuce : ajoutez un bloc {block} à config.json pour avoir l'Assistant, qui explique ici les problèmes de connexion."
  },
  "es": {
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Los accesorios de la app Casa en Homeswift, a través de Homeswift Wingman en un Mac. Se suman a la página Accesorios, las escenas y el Asistente, y quedan fuera de HomeKit, que ya los tiene.",
    "Your Wingmen": "Tus Wingman",
    "Wingman no longer knows this bridge. Pair it again on Add accessories.": "Wingman ya no conoce este puente. Vuelve a emparejarlo en Añadir accesorios.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then pair it on Add accessories.": "Aún no hay ningún Wingman emparejado. Abre Homeswift Wingman en un Mac de la casa y emparéjalo en Añadir accesorios.",
    "Pair a Wingman": "Emparejar un Wingman",
    "Add accessories finds Homeswift Wingman on this network: compare its certificate, then type the code its menu shows. For a Mac Bonjour does not reach, add its address to this plugin's settings first.": "Añadir accesorios encuentra Homeswift Wingman en esta red: compara su certificado y escribe el código que muestra su menú. Para un Mac al que Bonjour no llega, añade antes su dirección a los ajustes de este plugin.",
    "Connected": "Conectado",
    "Connecting…": "Conectando…",
    "Pair again": "Volver a emparejar",
    "Not reachable": "Inaccesible",
    "Apple Home": "la app Casa",
    "updated {when}": "actualizado {when}",
    "Accessories": "Accesorios",
    "Not responding": "No responden",
    "Left out": "Excluidos",
    "Homeswift's own accessories, and those left out in the settings": "Los accesorios de Homeswift, y los excluidos en los ajustes",
    "Certificate pinned": "Certificado fijado",
    "Actions for {name}": "Acciones para {name}",
    "Show its log": "Ver su registro",
    "Ask the Assistant": "Preguntar al Asistente",
    "About my Wingman {name}: ": "Sobre mi Wingman {name}: ",
    "Remove": "Eliminar",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "¿Eliminar {name}? Sus accesorios de la app Casa salen de Homeswift. Quita también este puente de los puentes emparejados de Wingman.",
    "Paired": "Emparejado",
    "Pair": "Emparejar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que explica aquí los problemas de conexión."
  },
  "pt": {
    "The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, scenes and the Assistant, and stay out of HomeKit, which has them already.": "Os acessórios da app Casa no Homeswift, através do Homeswift Wingman num Mac. Juntam-se à página Acessórios, às cenas e ao Assistente, e ficam fora do HomeKit, que já os tem.",
    "Your Wingmen": "Os seus Wingman",
    "Wingman no longer knows this bridge. Pair it again on Add accessories.": "O Wingman já não conhece esta ponte. Emparelhe-o de novo em Adicionar acessórios.",
    "No Wingman paired yet. Open Homeswift Wingman on a Mac in this home, then pair it on Add accessories.": "Ainda não há nenhum Wingman emparelhado. Abra o Homeswift Wingman num Mac da casa e emparelhe-o em Adicionar acessórios.",
    "Pair a Wingman": "Emparelhar um Wingman",
    "Add accessories finds Homeswift Wingman on this network: compare its certificate, then type the code its menu shows. For a Mac Bonjour does not reach, add its address to this plugin's settings first.": "Adicionar acessórios encontra o Homeswift Wingman nesta rede: compare o certificado e introduza o código que o menu mostra. Para um Mac que o Bonjour não alcança, adicione primeiro o endereço às definições deste plugin.",
    "Connected": "Ligado",
    "Connecting…": "A ligar…",
    "Pair again": "Emparelhar de novo",
    "Not reachable": "Inacessível",
    "Apple Home": "a app Casa",
    "updated {when}": "atualizado {when}",
    "Accessories": "Acessórios",
    "Not responding": "Não respondem",
    "Left out": "Excluídos",
    "Homeswift's own accessories, and those left out in the settings": "Os acessórios do Homeswift, e os excluídos nas definições",
    "Certificate pinned": "Certificado fixado",
    "Actions for {name}": "Ações para {name}",
    "Show its log": "Ver o seu registo",
    "Ask the Assistant": "Perguntar ao Assistente",
    "About my Wingman {name}: ": "Sobre o meu Wingman {name}: ",
    "Remove": "Remover",
    "Remove {name}? Its Apple Home accessories leave Homeswift. Remove this bridge from Wingman's Paired Bridges too.": "Remover {name}? Os seus acessórios da app Casa saem do Homeswift. Retire também esta ponte das pontes emparelhadas do Wingman.",
    "Paired": "Emparelhado",
    "Pair": "Emparelhar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Dica: adicione um bloco {block} ao config.json para ter o Assistente, que explica aqui os problemas de ligação."
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
  /* The card to Add accessories, then a card per paired Wingman on the UI's materials (its state as facts). */
  .wingman { display: grid; gap: 14px; align-content: start; animation: materialize var(--normal) var(--ease-out); }
  .wingman.redrawn { animation: none; }
  .wingman .note { margin: 0; }
  .wingman .actions { margin: 0; }
  #setup { margin-bottom: 16px; }
  .facts.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .fact.warn b { color: var(--warn); }
  .hint { margin: 14px 0 0; padding: 10px 14px; border-radius: 14px; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.8125rem; }
  @media (prefers-reduced-motion: reduce) { .wingman { animation: none; } }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large tone-orange" aria-hidden="true"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 320"><g fill="currentColor" stroke="none"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/><g transform="translate(500 0) scale(-1 1)"><path d="M8 12C65 48 155 88 180 110C198 121 204 136 195 148L165 177C180 144 170 131 149 121C47 95 6 88 8 12Z M36 112L150 152L132 177C64 163 42 161 36 112Z M58 177L121 193L109 221C77 220 63 203 58 177Z"/></g></g><path d="M136 220L250 104L364 220M153 205V305H347V205" fill="none" stroke="currentColor" stroke-width="29" stroke-linecap="round" stroke-linejoin="round"/></svg></span>
    <div class="who">
      <h1>Wingman</h1>
      <p class="muted" data-i18n>The Home app's accessories in Homeswift, through Homeswift Wingman on a Mac. They join the Accessories page, scenes and the Assistant, and stay out of HomeKit, which has them already.</p>
    </div>
  </div>
  <div id="setup"></div>
  <div class="section-head"><h2 data-i18n>Your Wingmen</h2></div>
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
