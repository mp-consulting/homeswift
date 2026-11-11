// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension WingmanPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The Wingman page: the paired Wingmen, refreshed every two seconds while the page is visible, a card redrawn only
// when it changed. A Wingman is found and paired on Add accessories (Setup: the certificate to compare, then the
// six-digit code its menu shows): the page leads there. It writes no settings (docs/adr/0002-schema-declares-every-setting.md):
// a Wingman's Settings sheet Excludes or Forgets it, and the plugin's Settings list the mirrored accessories and bridges.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, tile, fact, request, explain, assistant, platform, poll, renderKeyed, setupCard, setupAddress } = homeswift;
  const { ago } = HomeswiftCommon;

  const list = $("#wingmen");

  // MARK: Where settings are edited: the plugin's Settings page (its devices: the Wingmen, the mirrored accessories and
  // the bridges), and each Wingman's Settings sheet there.

  const settingsOf = (id) => homeswift.accessorySettings(`${platform}:${id}`);

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
          { label: t("Settings"), icon: "gear", href: settingsOf(wingman.id) },
        ])));
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

  // MARK: Apple Home's hidden groups: those of fewer than two accessories, which the Home app does not show. An
  // interrupted creation can leave one: it keeps its name (a group of that name is refused) and counts towards HomeKit's
  // limit. Each can be removed, or all of them, once confirmed.

  const hidden = $("#hidden-groups");

  async function loadHiddenGroups() {
    let answer;
    try { answer = await request("empty-groups"); } catch (e) {
      hidden.replaceChildren(el("div", { class: "card hidden-groups" }, el("p", { class: "muted note", text: e.status === 409 ? t("Link this bridge to its home in Apple Home to see its hidden groups.") : e.message })));
      return;
    }
    const groups = answer.groups || [];
    const why = el("p", { class: "muted note", text: t("Groups of fewer than two accessories, which the Home app does not show. An interrupted group creation can leave one: it keeps the name, so a new group of that name is refused, and it counts towards Apple Home's limit.") });
    if (!groups.length) {
      hidden.replaceChildren(el("div", { class: "card hidden-groups" }, why, el("p", { class: "note", text: t("No hidden groups in {home}.", { home: answer.home }) })));
      return;
    }
    hidden.replaceChildren(el("div", { class: "card hidden-groups" }, why,
      el("div", { class: "rows" }, groups.map((group) => el("div", { class: "row" },
        el("div", { class: "who" }, el("strong", { text: group.name }),
          el("span", { class: "muted", text: group.accessories ? t("1 accessory") : t("No accessories") })),
        el("button", { type: "button", class: "icon-button danger", "aria-label": t("Remove {name}", { name: group.name }), title: t("Remove {name}", { name: group.name }),
          onclick: () => removeGroups([group], answer.home) }, HomeswiftCommon.icon("trash"))))),
      el("div", { class: "actions" }, el("button", { type: "button", class: "danger", actionIcon: "trash", text: t("Remove all"),
        onclick: () => removeGroups(groups, answer.home) }))));
  }

  async function removeGroups(groups, home) {
    const one = groups.length === 1;
    const confirmed = await HomeswiftCommon.confirmAction({
      title: one ? t("Remove the group {name}?", { name: groups[0].name }) : tn("Remove {n} hidden group?", "Remove {n} hidden groups?", groups.length),
      text: one ? t("It is removed from {home} in Apple Home. It holds no accessory there, so nothing else changes.", { home })
        : t("They are removed from {home} in Apple Home. None holds an accessory there, so nothing else changes.", { home }),
      confirmLabel: t("Remove"), confirmIcon: "trash" });
    if (!confirmed) return;
    try {
      const result = await request("empty-groups/remove", { method: "POST", body: { ids: groups.map((group) => group.id) } });
      const failed = (result.failed || []).map((group) => t("{name}: {error}", { name: group.name, error: group.error }));
      if (failed.length) HomeswiftCommon.showAlert(failed.join("\n"));
    } catch (e) { HomeswiftCommon.showAlert(e.message); }
    loadHiddenGroups();
  }

  loadHiddenGroups();

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
    "Hidden groups in Apple Home": "Groupes masqués dans l'app Maison",
    "Link this bridge to its home in Apple Home to see its hidden groups.": "Reliez ce pont à sa maison dans l'app Maison pour voir ses groupes masqués.",
    "Groups of fewer than two accessories, which the Home app does not show. An interrupted group creation can leave one: it keeps the name, so a new group of that name is refused, and it counts towards Apple Home's limit.": "Des groupes de moins de deux accessoires, que l'app Maison n'affiche pas. Une création de groupe interrompue peut en laisser un : il garde le nom, si bien qu'un nouveau groupe de ce nom est refusé, et il compte dans la limite de l'app Maison.",
    "No hidden groups in {home}.": "Aucun groupe masqué dans {home}.",
    "1 accessory": "1 accessoire",
    "No accessories": "Aucun accessoire",
    "Remove {name}": "Supprimer {name}",
    "Remove all": "Tout supprimer",
    "Remove the group {name}?": "Supprimer le groupe {name} ?",
    "Remove {n} hidden group?": "Supprimer {n} groupe masqué ?",
    "Remove {n} hidden groups?": "Supprimer {n} groupes masqués ?",
    "It is removed from {home} in Apple Home. It holds no accessory there, so nothing else changes.": "Il est supprimé de {home} dans l'app Maison. Il n'y contient aucun accessoire, donc rien d'autre ne change.",
    "They are removed from {home} in Apple Home. None holds an accessory there, so nothing else changes.": "Ils sont supprimés de {home} dans l'app Maison. Aucun n'y contient d'accessoire, donc rien d'autre ne change.",
    "Remove": "Supprimer",
    "{name}: {error}": "{name} : {error}",
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
    "Paired": "Jumelé",
    "Pair": "Jumeler",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Astuce : ajoutez un bloc {block} à config.json pour avoir l'Assistant, qui explique ici les problèmes de connexion.",
    "Settings": "Réglages"
  },
  "es": {
    "Hidden groups in Apple Home": "Grupos ocultos en la app Casa",
    "Link this bridge to its home in Apple Home to see its hidden groups.": "Vincula este puente a su casa en la app Casa para ver sus grupos ocultos.",
    "Groups of fewer than two accessories, which the Home app does not show. An interrupted group creation can leave one: it keeps the name, so a new group of that name is refused, and it counts towards Apple Home's limit.": "Grupos de menos de dos accesorios, que la app Casa no muestra. Una creación de grupo interrumpida puede dejar uno: conserva el nombre, así que se rechaza un grupo nuevo con ese nombre, y cuenta para el límite de la app Casa.",
    "No hidden groups in {home}.": "No hay grupos ocultos en {home}.",
    "1 accessory": "1 accesorio",
    "No accessories": "Sin accesorios",
    "Remove {name}": "Eliminar {name}",
    "Remove all": "Eliminar todos",
    "Remove the group {name}?": "¿Eliminar el grupo {name}?",
    "Remove {n} hidden group?": "¿Eliminar {n} grupo oculto?",
    "Remove {n} hidden groups?": "¿Eliminar {n} grupos ocultos?",
    "It is removed from {home} in Apple Home. It holds no accessory there, so nothing else changes.": "Se elimina de {home} en la app Casa. No contiene ningún accesorio allí, así que nada más cambia.",
    "They are removed from {home} in Apple Home. None holds an accessory there, so nothing else changes.": "Se eliminan de {home} en la app Casa. Ninguno contiene accesorios allí, así que nada más cambia.",
    "Remove": "Eliminar",
    "{name}: {error}": "{name}: {error}",
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
    "Paired": "Emparejado",
    "Pair": "Emparejar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Consejo: añade un bloque {block} a config.json para tener el Asistente, que explica aquí los problemas de conexión.",
    "Settings": "Ajustes"
  },
  "pt": {
    "Hidden groups in Apple Home": "Grupos ocultos na app Casa",
    "Link this bridge to its home in Apple Home to see its hidden groups.": "Ligue esta ponte à sua casa na app Casa para ver os grupos ocultos.",
    "Groups of fewer than two accessories, which the Home app does not show. An interrupted group creation can leave one: it keeps the name, so a new group of that name is refused, and it counts towards Apple Home's limit.": "Grupos com menos de dois acessórios, que a app Casa não mostra. Uma criação de grupo interrompida pode deixar um: fica com o nome, por isso um novo grupo com esse nome é recusado, e conta para o limite da app Casa.",
    "No hidden groups in {home}.": "Não há grupos ocultos em {home}.",
    "1 accessory": "1 acessório",
    "No accessories": "Sem acessórios",
    "Remove {name}": "Remover {name}",
    "Remove all": "Remover todos",
    "Remove the group {name}?": "Remover o grupo {name}?",
    "Remove {n} hidden group?": "Remover {n} grupo oculto?",
    "Remove {n} hidden groups?": "Remover {n} grupos ocultos?",
    "It is removed from {home} in Apple Home. It holds no accessory there, so nothing else changes.": "É removido de {home} na app Casa. Não contém nenhum acessório lá, por isso nada mais muda.",
    "They are removed from {home} in Apple Home. None holds an accessory there, so nothing else changes.": "São removidos de {home} na app Casa. Nenhum contém acessórios lá, por isso nada mais muda.",
    "Remove": "Remover",
    "{name}: {error}": "{name}: {error}",
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
    "Paired": "Emparelhado",
    "Pair": "Emparelhar",
    "Tip: add a {block} block to config.json to get the Assistant, which explains connection problems here.": "Dica: adicione um bloco {block} ao config.json para ter o Assistente, que explica aqui os problemas de ligação.",
    "Settings": "Definições"
  }
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
  /* Apple Home's groups the Home app does not show (fewer than two accessories): a row each, a red bin to remove it. */
  .hidden-groups { display: grid; gap: 12px; }
  .hidden-groups .note { margin: 0; }
  .hidden-groups .rows { border: 1px solid var(--line); border-radius: 14px; overflow: hidden; }
  .hidden-groups .row .who { display: grid; gap: 2px; }
  .hidden-groups .row .who .muted { font-size: 0.8125rem; }
  .hidden-groups .row .icon-button { width: 32px; min-width: 32px; height: 32px; min-height: 32px; color: var(--error); }
  @media (pointer: coarse) { .hidden-groups .row .icon-button { width: 40px; min-width: 40px; height: 40px; min-height: 40px; } }
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
  <div class="section-head"><h2 data-i18n>Hidden groups in Apple Home</h2></div>
  <div id="hidden-groups"></div>
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
