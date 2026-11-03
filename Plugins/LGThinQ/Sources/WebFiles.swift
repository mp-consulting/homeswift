// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension LGThinQPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page, after the Homebridge plugin's settings page without its settings: the LG account (signed out, a card
// to Setup on Add accessories, which signs in; signed in, its region and way, with Sign in again), then the account's
// appliances with where each stands. It writes no settings (docs/adr/0002-schema-declares-every-setting.md): the plugin's
// are on its Settings page, and an appliance's row opens its own there (its options, Exclude and Include).
(() => {
  "use strict";
  const { $, el, request, explain } = homeswift;
  const { t } = HomeswiftI18n;

  // State: the sign-in's state and the account's devices.
  let account = {};
  let devices = [];

  /// Runs `work` with the button disabled and a spinner on it; errors reach the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Where settings are edited: the plugin's Settings page, and each appliance's there.

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const deviceSettings = (id) => `${pluginSettings}?accessory=${encodeURIComponent(`LGThinQ:${id}`)}`;

  // MARK: Problems, with the Assistant's explanation when it is set up

  // What the Assistant may see: the region and way, never the email, password, refresh token or device ids.
  const assistantContext = (extra) => [
    extra,
    `Auth mode: ${account.authMode || "token"}.`,
    `Account region: country ${account.country || "unset"}, language ${account.language || "unset"}.`,
  ].filter(Boolean).join(" ");

  function showProblem(container, message, context) {
    container.classList.remove("hidden");
    container.replaceChildren(el("p", { class: "error", text: message }), explain({ error: message, context: assistantContext(context) }));
  }
  function clearProblem(container) {
    container.classList.add("hidden");
    container.replaceChildren();
  }

  // MARK: The account, signed in through Setup

  // A region named in the page's language (Intl.DisplayNames), its language by its own name; the codes otherwise.
  const displayNames = (locale, type) => { try { return new Intl.DisplayNames([locale], { type }); } catch { return null; } };
  function regionText(country, language) {
    if (!country || !language) return "—";
    try {
      const region = displayNames(HomeswiftI18n.locale, "region")?.of(country) || country;
      const primary = language.split("-")[0];
      const speech = displayNames(primary, "language")?.of(primary) || language;
      return `${region} / ${speech}`;
    } catch { return `${country} / ${language}`; }
  }

  $("#sign-in-again").href = homeswift.setupAddress({ start: true });

  /// The sign-in's state: signed out, the card to Setup; signed in, its facts and the devices.
  function renderAccount() {
    const signedIn = !!account.authorized;
    $("#account").classList.toggle("hidden", !signedIn);
    $("#account-setup").replaceChildren(signedIn ? "" : homeswift.setupCard({
      title: t("Sign in to your LG account"),
      text: t("Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done."),
      glyph: "key",
    }));
    if (!signedIn) return;
    $("#account-region").textContent = regionText(account.country, account.language);
    $("#account-mode").textContent = account.authMode === "account" ? t("Email and password") : t("LG's sign-in page");
    $("#account-email-row").classList.toggle("hidden", !account.username);
    $("#account-email").textContent = account.username || "";
  }

  // MARK: The account's appliances

  const list = $("#device-list");
  const typeOf = (device) => String(device.type || t("Unknown"));

  /// Where an appliance stands: in HomeKit, Excluded, left out by a Homebridge block's list, or not supported.
  function standing(device) {
    if (device.running) return el("span", { class: "pill on", text: t("In HomeKit") });
    if (!device.supported) return el("span", { class: "pill", text: t("Not supported") });
    if (device.excluded || device.configured === false) return el("span", { class: "pill", text: t("Excluded") });
    return null;
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    if (!devices.length) {
      list.replaceChildren(el("li", { class: "empty muted", text: t("No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.") }));
      return;
    }
    list.replaceChildren(...devices.map((device) => {
      const online = device.online !== false;
      return el("li", { class: "device" },
        el("div", { class: "who" }, el("strong", { text: device.name }),
          el("div", { class: "meta muted" }, el("span", { text: typeOf(device) }), " · ", el("span", { class: "id mono", text: t("ID: {id}", { id: device.id }) }))),
        online ? null : explain({
          error: "The LG ThinQ cloud reports this appliance as offline (not connected to LG).",
          context: assistantContext("The user is looking at the device list of the LG ThinQ plugin page."),
          device: { name: device.name, type: typeOf(device), online, inHomeKit: !!device.running },
        }),
        standing(device),
        el("span", { class: `pill status ${online ? "on" : "away"}`, text: online ? t("Online") : t("Offline") }),
        device.supported ? el("a", { class: "button small", href: deviceSettings(device.id), actionIcon: "gear", text: t("Settings"),
          "aria-label": t("Settings of {name}", { name: device.name }) }) : null);
    }));
  }

  async function loadDevices() {
    const problem = $("#devices-problem");
    clearProblem(problem);
    await act($("#refresh"), async () => {
      try {
        devices = (await request("account-devices")).devices || [];
        renderDevices();
      } catch (e) {
        showProblem(problem, HomeswiftI18n.message(e.message) || t("Failed to load devices"),
          "Loading the device list of the account this instance signed in with from the LG ThinQ cloud failed on the plugin page.");
      }
    });
  }

  $("#refresh").addEventListener("click", () => loadDevices());

  // MARK: Start: the sign-in, then the account's devices once signed in

  (async () => {
    try {
      account = await request("account");
    } catch (e) {
      showProblem($("#account-problem"), e.message);
    }
    renderAccount();
    $("#step-devices").classList.toggle("hidden", !account.authorized);
    if (account.authorized) await loadDevices();
  })();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The LG ThinQ page's strings and the plugin's errors in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Connect your LG account to manage its appliances in HomeKit.": "Connectez votre compte LG pour gérer ses appareils dans HomeKit.",
    "Email": "E-mail",
    "Your devices": "Vos appareils",
    "Settings": "Réglages",
    "Devices in your account": "Appareils de votre compte",
    "Refresh": "Actualiser",
    "Region": "Région",
    "ThinQ1 support": "Prise en charge de ThinQ1",
    "Failed to load devices": "Impossible de charger les appareils",
    "Unknown": "Inconnu",
    "ID: {id}": "ID : {id}",
    "In HomeKit": "Dans HomeKit",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Settings of {name}": "Réglages de {name}",
    "Name": "Nom",
    "LG ThinQ did not answer; try again later.": "LG ThinQ n'a pas répondu ; réessayez plus tard.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken non valide : il ne doit pas être vide.",
    "Your account was already used to registered in {0}.": "Votre compte est déjà enregistré dans {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "LG a refusé la connexion. Si vous vous connectez à LG avec Google, Apple ou Facebook, utilisez plutôt un jeton.",
    "LG rejected the sign-in.": "LG a refusé la connexion.",
    "LG returned no account for this sign-in.": "LG n'a renvoyé aucun compte pour cette connexion.",
    "LG returned no authorization code.": "LG n'a renvoyé aucun code d'autorisation.",
    "LG returned no redirect.": "LG n'a renvoyé aucune redirection.",
    "LG returned no access token for the refresh token.": "LG n'a renvoyé aucun jeton d'accès pour le jeton d'actualisation.",
    "LG returned no user number.": "LG n'a renvoyé aucun numéro d'utilisateur.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "Impossible de lire la signature des conditions de LG. Ouvrez l'app LG ThinQ et acceptez les nouvelles conditions.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Ouvrez l'app LG et connectez-vous à votre compte pour voir ce qui s'est passé : de nouvelles conditions sont peut-être à accepter. Redémarrez ensuite Homeswift.",
    "Request failed with status code {0}": "La requête a échoué avec le code {0}",
    "not signed in": "non connecté",
    "Your LG account": "Votre compte LG",
    "Signed in with": "Connecté avec",
    "Sign in to your LG account": "Connectez-vous à votre compte LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "Homeswift se connecte dans Ajouter des accessoires, avec la page de connexion de LG (pour les comptes LG, Google, Apple, Facebook ou Amazon) ou l'e-mail et le mot de passe du compte. Ses appareils apparaissent ici une fois la connexion faite.",
    "Email and password": "E-mail et mot de passe",
    "LG's sign-in page": "La page de connexion de LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "Aucun appareil trouvé. Ajoutez-les à votre compte LG dans l'app LG ThinQ, puis appuyez sur Actualiser.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Cette instance n'a pas encore de connexion LG : connectez-vous d'abord dans Ajouter des accessoires.",
    "Not supported": "Non pris en charge",
    "Each appliance's options, and whether it is in HomeKit, are in its Settings. ThinQ1 support and its polling interval are on the plugin's Settings page.": "Les options de chaque appareil, et s'il est dans HomeKit, sont dans ses Réglages. La prise en charge de ThinQ1 et son intervalle d'interrogation sont sur la page Réglages du plugin."
  },
  "es": {
    "Connect your LG account to manage its appliances in HomeKit.": "Conecta tu cuenta de LG para gestionar sus electrodomésticos en HomeKit.",
    "Email": "Correo electrónico",
    "Your devices": "Tus dispositivos",
    "Settings": "Ajustes",
    "Devices in your account": "Dispositivos de tu cuenta",
    "Refresh": "Actualizar",
    "Region": "Región",
    "ThinQ1 support": "Compatibilidad con ThinQ1",
    "Failed to load devices": "No se han podido cargar los dispositivos",
    "Unknown": "Desconocido",
    "ID: {id}": "ID: {id}",
    "In HomeKit": "En HomeKit",
    "Online": "Conectado",
    "Offline": "Desconectado",
    "Settings of {name}": "Ajustes de {name}",
    "Name": "Nombre",
    "LG ThinQ did not answer; try again later.": "LG ThinQ no ha respondido; vuelve a intentarlo más tarde.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken no válido: no puede estar vacío.",
    "Your account was already used to registered in {0}.": "Tu cuenta ya está registrada en {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "LG ha rechazado el inicio de sesión. Si inicias sesión en LG con Google, Apple o Facebook, usa un token.",
    "LG rejected the sign-in.": "LG ha rechazado el inicio de sesión.",
    "LG returned no account for this sign-in.": "LG no ha devuelto ninguna cuenta para este inicio de sesión.",
    "LG returned no authorization code.": "LG no ha devuelto ningún código de autorización.",
    "LG returned no redirect.": "LG no ha devuelto ninguna redirección.",
    "LG returned no access token for the refresh token.": "LG no ha devuelto ningún token de acceso para el token de actualización.",
    "LG returned no user number.": "LG no ha devuelto ningún número de usuario.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "No se ha podido leer la firma de las condiciones de LG. Abre la app LG ThinQ y acepta las nuevas condiciones.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Abre la app de LG e inicia sesión en tu cuenta para ver qué ha pasado: quizá haya nuevas condiciones que aceptar. Después reinicia Homeswift.",
    "Request failed with status code {0}": "La solicitud ha fallado con el código {0}",
    "not signed in": "sin sesión iniciada",
    "Your LG account": "Tu cuenta de LG",
    "Signed in with": "Sesión iniciada con",
    "Sign in to your LG account": "Inicia sesión en tu cuenta de LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "Homeswift inicia sesión en Añadir accesorios, con la página de inicio de sesión de LG (para cuentas de LG, Google, Apple, Facebook o Amazon) o el correo electrónico y la contraseña de la cuenta. Sus electrodomésticos aparecen aquí una vez hecho.",
    "Email and password": "Correo electrónico y contraseña",
    "LG's sign-in page": "La página de inicio de sesión de LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "No se han encontrado dispositivos. Añádelos a tu cuenta de LG en la app LG ThinQ y pulsa Actualizar.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Esta instancia aún no tiene sesión de LG: inicia sesión primero en Añadir accesorios.",
    "Not supported": "No compatible",
    "Each appliance's options, and whether it is in HomeKit, are in its Settings. ThinQ1 support and its polling interval are on the plugin's Settings page.": "Las opciones de cada aparato, y si está en HomeKit, están en sus Ajustes. La compatibilidad con ThinQ1 y su intervalo de consulta están en la página Ajustes del plugin."
  },
  "pt": {
    "Connect your LG account to manage its appliances in HomeKit.": "Ligue a sua conta LG para gerir os eletrodomésticos no HomeKit.",
    "Email": "E-mail",
    "Your devices": "Os seus dispositivos",
    "Settings": "Definições",
    "Devices in your account": "Dispositivos da sua conta",
    "Refresh": "Atualizar",
    "Region": "Região",
    "ThinQ1 support": "Suporte de ThinQ1",
    "Failed to load devices": "Não foi possível carregar os dispositivos",
    "Unknown": "Desconhecido",
    "ID: {id}": "ID: {id}",
    "In HomeKit": "No HomeKit",
    "Online": "Online",
    "Offline": "Offline",
    "Settings of {name}": "Definições de {name}",
    "Name": "Nome",
    "LG ThinQ did not answer; try again later.": "O LG ThinQ não respondeu; tente novamente mais tarde.",
    "Invalid refreshToken: refreshToken must be a non-empty string.": "refreshToken inválido: não pode estar vazio.",
    "Your account was already used to registered in {0}.": "A sua conta já está registada em {0}.",
    "LG rejected the sign-in. If you sign in to LG with Google, Apple or Facebook, use a token instead.": "A LG recusou o início de sessão. Se inicia sessão na LG com Google, Apple ou Facebook, use um token.",
    "LG rejected the sign-in.": "A LG recusou o início de sessão.",
    "LG returned no account for this sign-in.": "A LG não devolveu nenhuma conta para este início de sessão.",
    "LG returned no authorization code.": "A LG não devolveu nenhum código de autorização.",
    "LG returned no redirect.": "A LG não devolveu nenhum redirecionamento.",
    "LG returned no access token for the refresh token.": "A LG não devolveu nenhum token de acesso para o token de atualização.",
    "LG returned no user number.": "A LG não devolveu nenhum número de utilizador.",
    "Could not read the terms signature from LG. Open the LG ThinQ app and accept the new terms.": "Não foi possível ler a assinatura dos termos da LG. Abra a app LG ThinQ e aceite os novos termos.",
    "Please open the native LG App and sign in to your account to see what happened, maybe new agreement need your accept. Then try restarting Homeswift.": "Abra a app da LG e inicie sessão na sua conta para ver o que aconteceu: talvez haja novos termos para aceitar. Depois reinicie o Homeswift.",
    "Request failed with status code {0}": "O pedido falhou com o código {0}",
    "not signed in": "sem sessão iniciada",
    "Your LG account": "A sua conta LG",
    "Signed in with": "Sessão iniciada com",
    "Sign in to your LG account": "Inicie sessão na sua conta LG",
    "Homeswift signs in on Add accessories, with LG's own sign-in page (for LG, Google, Apple, Facebook or Amazon accounts) or the account's email and password. Its appliances appear here once it is done.": "O Homeswift inicia sessão em Adicionar acessórios, com a página de início de sessão da LG (para contas LG, Google, Apple, Facebook ou Amazon) ou o e-mail e a palavra-passe da conta. Os eletrodomésticos aparecem aqui quando terminar.",
    "Email and password": "E-mail e palavra-passe",
    "LG's sign-in page": "A página de início de sessão da LG",
    "No devices found. Add them to your LG account in the LG ThinQ app, then press Refresh.": "Nenhum dispositivo encontrado. Adicione-os à sua conta LG na app LG ThinQ e prima Atualizar.",
    "This instance has no LG sign-in yet: sign in through Setup (Add accessories) first.": "Esta instância ainda não tem sessão LG: inicie sessão primeiro em Adicionar acessórios.",
    "Not supported": "Não suportado",
    "Each appliance's options, and whether it is in HomeKit, are in its Settings. ThinQ1 support and its polling interval are on the plugin's Settings page.": "As opções de cada aparelho, e se está no HomeKit, estão nas suas Definições. O suporte de ThinQ1 e o seu intervalo de consulta estão na página Definições do plugin."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LG ThinQ</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's settings page on the UI's materials, without its settings (the Settings page has them): the
     LG account (its sign-in, which Setup does), then the account's appliances. */

  .step { animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin: 22px 0 12px; }
  .step-head h2 { margin: 0; }
  .account { display: grid; gap: 12px; }
  .account .actions { margin: 0; }
  .problem { margin-top: 14px; }
  .problem .error { margin: 0; }

  .list-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
  .list-head h3 { margin: 0; }
  .list-head .count { margin-left: 6px; }
  .devices { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .device {
    display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px; padding: 10px 10px 10px 14px; border-radius: 14px;
    background: var(--material-thin); border: 1px solid var(--line);
  }
  .device .who { flex: 1; min-width: 0; }
  .device strong { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .device .meta { font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .device .explain { flex: none; }
  .list-foot { margin: 10px 0 0; font-size: 0.8125rem; }
  .empty { text-align: center; padding: 22px; border-radius: 14px; border: 1px dashed var(--line); }

  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .step { animation: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
  @media (max-width: 640px) {
    .device .meta .id { display: none; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="6" y="2.5" width="12" height="19" rx="2.5"/><path d="M10.5 18.5h3"/></svg></span>
    <div>
      <h1>LG ThinQ</h1>
      <p class="muted" data-i18n>Connect your LG account to manage its appliances in HomeKit.</p>
    </div>
  </div>

  <section id="step-account" class="step">
    <div class="step-head"><h2 data-i18n>Your LG account</h2></div>
    <div id="account-setup"></div>
    <div id="account" class="card account hidden">
      <div class="facts">
        <div class="fact"><span data-i18n>Region</span><b id="account-region">—</b></div>
        <div class="fact"><span data-i18n>Signed in with</span><b id="account-mode">—</b></div>
        <div class="fact hidden" id="account-email-row"><span data-i18n>Email</span><b id="account-email"></b></div>
      </div>
      <div class="actions"><a id="sign-in-again" class="button" href="/setup?start" data-i18n data-action-icon="key">Sign in again</a></div>
    </div>
    <div id="account-problem" class="problem hidden"></div>
  </section>

  <section id="step-devices" class="step hidden">
    <div class="step-head"><h2 data-i18n>Your devices</h2></div>
    <div class="card">
      <div class="list-head">
        <h3 data-i18n>Devices in your account <span id="device-count" class="pill count">0</span></h3>
        <div class="actions"><button id="refresh" data-i18n data-action-icon="restore">Refresh</button></div>
      </div>
      <div id="devices-problem" class="problem hidden"></div>
      <ul id="device-list" class="devices"></ul>
      <p class="list-foot muted" data-i18n>Each appliance's options, and whether it is in HomeKit, are in its Settings. ThinQ1 support and its polling interval are on the plugin's Settings page.</p>
    </div>
  </section>
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
