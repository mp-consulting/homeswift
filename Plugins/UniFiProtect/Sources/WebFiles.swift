// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension UniFiProtectPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Protect page: the controllers this instance runs, each with its state and its devices; finding a
// third-party camera's URLs over ONVIF; and the support links. It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): a controller's, a device's (a third-party camera's URLs among them)
// and the plugin's open the Settings pages, and another controller is set up in Add accessories.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, setupCard } = homeswift;
  const { t } = HomeswiftI18n;
  /// Text from the plugin (an error in an answer), in the page's language when the catalog knows it.
  const said = (text) => HomeswiftI18n.message(text);
  const P = window.ProtectOptions;
  const screens = ["controllersScreen", "onvifScreen", "supportScreen"];

  // MARK: Where settings are edited: the plugin's Settings page, and each controller's or device's there.

  const settingsOf = (mac) => homeswift.accessorySettings(`UniFi Protect:${String(mac).replace(/[:-]/g, "").toUpperCase()}`);

  function showScreen(id) {
    for (const screen of screens) $("#" + screen).classList.toggle("hidden", screen !== id);
  }

  function back() {
    breadcrumb(null);
    showScreen("controllersScreen");
    renderControllers();
  }

  /// Runs `work` with the button disabled and, when it takes a moment, a spinner on it; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  // MARK: Controllers

  async function renderControllers() {
    const list = $("#controllersList");
    let live = [];
    try {
      ({ controllers: live } = await request("controllers"));
    } catch (e) {
      list.replaceChildren(el("p", { class: "error", text: e.message }));
      return;
    }
    const setup = setupCard({
      title: live.length ? t("Another controller") : t("No controller yet"),
      text: t("Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account."),
    });
    list.replaceChildren(...live.map(controllerCard), setup);
  }

  function controllerCard(controller) {
    const badge = el("span", { class: "pill status standby", text: t("Checking") });
    const slot = el("div", {});
    const devices = controller.devices ?? [];
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("system")),
        el("div", { class: "who" }, el("strong", { text: controller.name || controller.address }), el("div", { class: "muted", text: controller.address })),
        badge),
      el("div", { class: "facts" },
        el("div", { class: "fact" }, el("span", { text: t("Devices") }), el("b", { text: String(devices.length) })),
        el("div", { class: "fact" }, el("span", { text: t("Events") }), el("b", { text: controller.events ? t("Live") : controller.connected ? t("Every 2 minutes") : "—" })),
        el("div", { class: "fact" }, el("span", { text: t("Certificate") }), el("b", { text: controller.tlsFingerprint ? t("Pinned") : t("Not yet seen") }))),
      slot,
      devices.length ? el("div", { class: "found" }, devices.map(deviceRow)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: controller.connected ? t("Connected") : t("Not connected yet: see the log.") }),
        controller.mac ? el("a", { class: "button", href: settingsOf(controller.mac), actionIcon: "gear", text: t("Settings") }) : null));
    request("check-status", { method: "POST", body: { address: controller.address } }).then(({ online }) => {
      badge.className = `pill status ${online ? "on" : "away"}`;
      badge.textContent = online ? t("Online") : t("Offline");
      if (!online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server; loopback and link-local addresses are refused), so it is shown as Offline.",
          context: "The user is looking at the UniFi Protect controllers the plugin runs in its page.",
          device: { name: controller.name, connected: controller.connected },
        }));
      }
    }).catch(() => { badge.textContent = t("Unknown"); });
    return card;
  }

  /// A device of a controller: its kind and state, and its Settings (a third-party camera's URLs among them).
  function deviceRow(device) {
    const kind = device.thirdParty ? t("Third-party camera") : device.modelKey;
    return el("div", { class: "card item" },
      el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon(device.modelKey === "camera" ? "camera" : device.modelKey === "light" ? "bulb" : "sensor")),
      el("div", {}, el("strong", { text: device.name }), el("div", { class: "muted", text: [kind, device.online ? t("Online") : t("Offline")].join(" · ") })),
      el("a", { class: "button", href: settingsOf(device.mac), actionIcon: "gear", text: t("Settings") }));
  }

  // MARK: A third-party camera's URLs, over ONVIF

  function say(text, kind = "") {
    const status = $("#onvifStatus");
    status.textContent = text;
    status.className = `status-line ${kind}`;
  }

  async function discoverOnvif() {
    const host = $("#onvifHost").value.trim();
    const username = $("#onvifUser").value.trim();
    const password = $("#onvifPass").value;
    const servicePath = $("#onvifPath").value.trim();
    const port = $("#onvifPort").value;
    const found = $("#onvifProfiles");
    found.replaceChildren();
    if (!host || !username) { say(t("IP address and username are required."), "error"); return; }
    say(t("Discovering…"));
    const assistantSlot = $("#onvifAssistant");
    assistantSlot.replaceChildren();
    const explainFailure = (message) => assistantSlot.replaceChildren(explain({
      error: P.scrubText(message, [host]),
      context: "Discovering the RTSP and snapshot URLs of a third-party camera over ONVIF from the plugin's page failed. Service path: "
        + (servicePath ? "custom" : "default (/onvif/device_service)") + ". Port: " + (port ? "set by the user" : "automatic") + ".",
    }));
    try {
      const result = await request("onvif", { method: "POST", body: { host, password, port: port ? parseInt(port, 10) : undefined, servicePath: servicePath || undefined, username } });
      if (!result?.ok) {
        say(t("Discovery failed: {error}", { error: result?.error ? said(result.error) : t("unknown error") }), "error");
        explainFailure("Discovery failed: " + (result?.error || "unknown error"));
        return;
      }
      const raw = (result.profiles || []).filter((p) => p.rtspUrl || p.snapshotUrl);
      if (!raw.length) { say(t("Camera did not return any URLs."), "warn"); return; }
      const profiles = P.dedupeProfilesByUrl(raw);
      const text = profiles.length > 1 ? t("Found {n} profiles on port {port}. Pick the one to use.", { n: profiles.length, port: String(result.port) })
        : t("Discovered URLs on port {port}.", { port: String(result.port) });
      say([text, ...(result.warnings || []).map(said)].join(" "), result.warnings?.length ? "warn" : "ok");
      found.replaceChildren(...profiles.map((profile, index) => profileRow(profile, index, host)));
    } catch (e) {
      say(t("Discovery failed: {error}", { error: e.message }), "error");
      explainFailure("Discovery failed: " + e.message);
    }
  }

  /// A profile's URLs to copy into the camera's Settings, with its snapshot, one profile at a time (cheap cameras
  /// drop parallel snapshot requests).
  let thumbnails = Promise.resolve();
  function profileRow(profile, index, host) {
    const thumb = el("span", { class: "thumb", text: t("No preview") });
    if (profile.snapshotUrl) {
      thumbnails = thumbnails.then(async () => {
        try {
          const result = await request("snapshot", { method: "POST", body: { host, url: profile.snapshotUrl } });
          if (result?.ok && result.data) thumb.replaceChildren(el("img", { alt: t("Stream preview"), src: `data:${result.contentType || "image/jpeg"};base64,${result.data}` }));
        } catch { /* no preview */ }
      });
    }
    const url = (label, value) => value ? el("div", { class: "muted" }, `${label}: `, el("span", { class: "mono", text: value })) : null;
    // common.js's copy: the Clipboard API, else a selection, for a page over plain HTTP on the network.
    const copy = () => HomeswiftCommon.copyText([profile.rtspUrl, profile.snapshotUrl].filter(Boolean).join("\n")).catch((e) => HomeswiftCommon.showAlert(e.message));
    return el("div", { class: "card item" }, thumb,
      el("div", {}, el("strong", { text: P.formatProfileLabel(profile, index) }), url(t("Direct RTSP / RTSPS URL"), profile.rtspUrl), url(t("Direct snapshot URL"), profile.snapshotUrl)),
      el("button", { type: "button", actionIcon: "copy", text: t("Copy"), onclick: copy }));
  }

  // MARK: Start

  function bind() {
    $("#onvifBtn").addEventListener("click", () => { showScreen("onvifScreen"); breadcrumb(t("Find a camera's URLs"), back); });
    $("#backFromOnvifBtn").addEventListener("click", back);
    $("#onvifDiscoverBtn").addEventListener("click", (event) => act(event.currentTarget, discoverOnvif));
    $("#supportBtn").addEventListener("click", () => { showScreen("supportScreen"); breadcrumb(t("Support"), back); });
    $("#backFromSupportBtn").addEventListener("click", back);
  }

  bind();
  showScreen("controllersScreen");
  renderControllers();
})();

"""#),
        "i18n.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The UniFi Protect page's strings, its feature options' descriptions and the text its plugin answers, in French, Spanish and Portuguese.
HomeswiftI18n.add({
  "fr": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Gérez vos caméras et appareils UniFi Protect dans HomeKit.",
    "Support": "Assistance",
    "Cancel": "Annuler",
    "Controller": "Contrôleur",
    "Username": "Nom d'utilisateur",
    "Password": "Mot de passe",
    "Feature options": "Options des fonctions",
    "Back": "Retour",
    "Scope": "Portée",
    "Global": "Global",
    "All devices": "Tous les appareils",
    "Device": "Appareil",
    "Model": "Modèle",
    "Status": "État",
    "IP address": "Adresse IP",
    "e.g. 192.168.1.50": "p. ex. 192.168.1.50",
    "ONVIF port": "Port ONVIF",
    "(optional)": "(facultatif)",
    "auto": "auto",
    "Service path": "Chemin du service",
    "(optional, /onvif/device_service by default)": "(facultatif, /onvif/device_service par défaut)",
    "Discover URLs": "Découvrir les URL",
    "Stream preview": "Aperçu du flux",
    "No preview": "Aucun aperçu",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directe",
    "Direct snapshot URL": "URL d'instantané directe",
    "Discard": "Annuler les modifications",
    "Save": "Enregistrer",
    "About this plugin": "À propos de ce plugin",
    "The Homeswift port of": "Le portage pour Homeswift de",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "Sa documentation s'applique ici : les options, les options des fonctions et les sujets MQTT sont les mêmes.",
    "Getting started": "Premiers pas",
    "Install, configure and connect to HomeKit.": "Installer, configurer et connecter à HomeKit.",
    "Options for a controller or a device.": "Les options d'un contrôleur ou d'un appareil.",
    "How to configure MQTT support.": "Comment configurer la prise en charge de MQTT.",
    "How-to guides": "Guides pratiques",
    "Doorbells": "Sonnettes",
    "Two-way audio, ring events and LCD messages.": "Audio bidirectionnel, événements de sonnerie et messages LCD.",
    "HKSV with Protect cameras.": "HKSV avec les caméras Protect.",
    "Liveview scenes": "Scènes Liveview",
    "Motion detection scenes and the security system.": "Les scènes de détection de mouvement et le système de sécurité.",
    "Troubleshooting": "Dépannage",
    "Login, network and video problems.": "Problèmes de connexion, de réseau et de vidéo.",
    "Checking": "Vérification",
    "Devices": "Appareils",
    "Events": "Événements",
    "Live": "En direct",
    "Every 2 minutes": "Toutes les 2 minutes",
    "Certificate": "Certificat",
    "Verified": "Vérifié",
    "Pinned": "Épinglé",
    "Not yet seen": "Pas encore vu",
    "Connected": "Connecté",
    "Not connected yet: see the log.": "Pas encore connecté : consultez le journal.",
    "Not running": "Arrêté",
    "Actions for {name}": "Actions pour {name}",
    "Edit": "Modifier",
    "Remove": "Supprimer",
    "Online": "En ligne",
    "Offline": "Hors ligne",
    "Unknown": "Inconnu",
    "Select": "Choisir",
    "Cameras": "Caméras",
    "Chimes": "Carillons",
    "Lights": "Lampes",
    "Sensors": "Capteurs",
    "Viewers": "Écrans",
    "Camera": "Caméra",
    "Intermediate": "Intermédiaire",
    "second": "seconde",
    "seconds": "secondes",
    "minute": "minute",
    "minutes": "minutes",
    "hour": "heure",
    "hours": "heures",
    "millisecond": "milliseconde",
    "milliseconds": "millisecondes",
    "decibel": "décibel",
    "decibels": "décibels",
    "Hertz": "hertz",
    "kilobits per second": "kilobits par seconde",
    "percentage": "pourcentage",
    "global": "global",
    "controller": "contrôleur",
    "device": "appareil",
    "none": "aucune",
    "IP address and username are required.": "L'adresse IP et le nom d'utilisateur sont requis.",
    "Discovering…": "Découverte…",
    "Discovery failed: {error}": "Échec de la découverte : {error}",
    "unknown error": "erreur inconnue",
    "Camera did not return any URLs.": "La caméra n'a renvoyé aucune URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "{n} profils trouvés sur le port {port}. Choisissez celui à utiliser.",
    "Discovered URLs on port {port}.": "URL découvertes sur le port {port}.",
    "Profile {n}": "Profil {n}",
    "this camera": "cette caméra",
    "this chime": "ce carillon",
    "this device": "cet appareil",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Délai dépassé après {0} s d'attente d'une réponse de {1}. Vérifiez que l'adresse et les identifiants sont corrects et que le contrôleur est joignable depuis cette machine Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0} : erreur d'API : identifiants de connexion non valides. Vérifiez votre nom d'utilisateur et votre mot de passe.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0} : erreur d'API : privilèges insuffisants pour cet utilisateur. Vérifiez les rôles attribués à cet utilisateur et assurez-vous qu'il dispose des privilèges nécessaires.",
    "{0}: API error: Connection refused.": "{0} : erreur d'API : connexion refusée.",
    "{0}: API error: Connection timed out.": "{0} : erreur d'API : la connexion a expiré.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0} : erreur d'API : nom d'hôte ou adresse IP introuvable : {1}. Vérifiez que l'adresse configurée pour ce contrôleur UniFi Protect est correcte.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0} : erreur d'API : impossible de se connecter au contrôleur Protect. C'est temporaire et peut arriver pendant le redémarrage des appareils.",
    "Invalid address.": "Adresse non valide.",
    "Unable to resolve {0}.": "Impossible de résoudre {0}.",
    "Connections to {0} are not permitted.": "Les connexions à {0} ne sont pas autorisées.",
    "ONVIF request timed out": "La requête ONVIF a expiré",
    "host and username are required.": "l'hôte et le nom d'utilisateur sont requis.",
    "No reachable ONVIF service on {0} ({1}).": "Aucun service ONVIF joignable sur {0} ({1}).",
    "Camera did not return a Media service capability.": "La caméra n'a pas indiqué de service Media.",
    "Camera did not return a Media service XAddr.": "La caméra n'a pas renvoyé de XAddr pour le service Media.",
    "Camera returned no media profiles.": "La caméra n'a renvoyé aucun profil média.",
    "The camera advertised its media service on a different host. Using {0} instead.": "La caméra annonce son service média sur un autre hôte. {0} est utilisé à la place.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "La caméra a renvoyé des URL de flux ou d'instantané sur un autre hôte que {0}. Les identifiants n'ont pas été ajoutés à ces URL.",
    "Audio": "Audio",
    "Doorbell": "Sonnette",
    "Logging": "Journalisation",
    "Motion": "Mouvement",
    "Security System": "Système de sécurité",
    "Sensor": "Capteur",
    "Video": "Vidéo",
    "Audio support.": "Prise en charge de l'audio.",
    "Audio filter for ambient noise suppression.": "Filtre audio de suppression du bruit ambiant.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Niveau de réduction du bruit, en décibels, pour le filtre afftdn de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Fréquence, en hertz, pour le filtre highpass de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Fréquence, en hertz, pour le filtre lowpass de FFmpeg.",
    "Two-way audio support on supported cameras.": "Audio bidirectionnel sur les caméras compatibles.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Envoyer l'audio bidirectionnel directement aux caméras compatibles, sans passer par le contrôleur. Utile pour contourner des bugs de certaines versions du firmware des contrôleurs Protect.",
    "Make this device available in HomeKit.": "Rendre cet appareil disponible dans HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Activer le voyant d'état de cet appareil dans HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Ajouter un accessoire interrupteur pour contrôler le voyant d'état dans HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Activer le voyant de vision nocturne de cet appareil dans HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Ajouter un accessoire variateur pour contrôler la vision nocturne dans HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Faire de cet appareil un accessoire autonome dans HomeKit, à ajouter séparément depuis l'app Maison.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tenter de redémarrer les appareils qui fonctionnent mal. Cela se fait toujours avec une grande prudence, et seulement après des problèmes prolongés propres à l'appareil.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Synchroniser le nom UniFi Protect de cet appareil avec HomeKit. La synchronisation est à sens unique : le nom va d'UniFi Protect vers HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Ajouter un capteur de contact qui s'active quand une empreinte digitale ou un badge NFC est authentifié sur une sonnette Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Ajouter un accessoire interrupteur pour choisir si HomeKit sonne quand on appuie sur la sonnette.",
    "Enable the doorbell messages feature.": "Activer la fonction des messages de la sonnette.",
    "Use messages saved to the Protect NVR as message switches.": "Utiliser les messages enregistrés sur le NVR Protect comme interrupteurs de message.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Ajouter un accessoire variateur pour contrôler le volume du carillon Protect dans HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Ajouter des accessoires interrupteurs pour contrôler les carillons physiques reliés à une sonnette Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Durée de la sonnerie, en millisecondes, d'un carillon physique numérique relié à une sonnette Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Ajouter un accessoire lampe pour contrôler la lampe de la caméra à colis d'une sonnette Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Ajouter un accessoire interrupteur pour déclencher des événements de sonnerie sur une caméra ou une sonnette Protect.",
    "Log doorbell ring events in Homebridge.": "Consigner les événements de sonnerie dans Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Consigner les événements d'enregistrement HomeKit Secure Video dans Homebridge.",
    "Log motion events in Homebridge.": "Consigner les événements de mouvement dans Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Durée, en secondes, d'un événement de mouvement avant d'en autoriser un nouveau.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Ajouter un accessoire capteur de présence qui déduit la présence de l'activité du détecteur de mouvement. Par défaut, tout mouvement déclenche la présence. Si l'option détection intelligente est activée, elle est utilisée à la place.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Durée, en secondes, à attendre sans événement de mouvement avant de considérer que la présence n'est plus détectée.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des animaux de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des visages de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des plaques d'immatriculation de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des colis de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des personnes de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection des véhicules de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des pleurs de bébé de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des aboiements de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes de voiture de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des klaxons de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes CO de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des bris de glace de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des sirènes de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes de fumée de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio de la parole de UniFi Protect pour déclencher la présence.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Si les options capteur de présence et détection intelligente sont activées, utiliser la détection audio des alarmes CO et fumée de UniFi Protect pour déclencher la présence.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Utiliser la détection intelligente de UniFi Protect pour les événements de mouvement HomeKit sur un appareil compatible.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Ajouter des capteurs de contact pour chaque type d'objet de la détection intelligente que UniFi Protect prend en charge.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Ajouter un accessoire capteur de contact qui correspond à une plaque d'immatriculation précise détectée par UniFi Protect. Vous pouvez indiquer plusieurs plaques en les séparant par des tirets (p. ex. PLAQUE1-PLAQUE2-PLAQUE3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Ajouter un accessoire interrupteur pour activer ou désactiver la détection de mouvement dans HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Ajouter un accessoire interrupteur pour déclencher manuellement un événement de détection de mouvement dans HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publier une playlist M3U des caméras Protect sur le port indiqué de ce serveur Homebridge, utilisable dans des apps (p. ex. Channels DVR) capables de diffuser les flux en direct des caméras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Délai, en secondes, avant de supprimer les appareils qui ne sont plus détectés sur le contrôleur Protect. Si l'option est désactivée, les appareils sont supprimés en temps réel, en même temps que sur le contrôleur Protect.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publier sur MQTT toute la télémétrie en temps réel reçue du contrôleur Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Ajouter des accessoires interrupteurs pour contrôler l'enregistrement natif du NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Ajouter des accessoires capteurs pour afficher les informations système du contrôleur Protect (pour l'instant, seulement la température).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Ajouter un accessoire interrupteur pour déclencher l'accessoire système de sécurité, avec l'option liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Présenter le capteur de fuite Protect comme un capteur de contact plutôt qu'un capteur de fuite. Utile pour les automatisations, car les capteurs de contact HomeKit offrent plus d'options d'automatisation que les capteurs de fuite, conçus surtout pour les alertes.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Ajouter un accessoire serrure pour déverrouiller. Pour l'instant, Protect ne permet de déverrouiller que les lecteurs Access dotés d'une caméra, sur le même contrôleur que Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Utiliser le transcodage accéléré par le matériel quand il est disponible (Mac Apple, processeurs Intel avec Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Utiliser l'API de diffusion en direct native de Protect pour afficher les flux en direct.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Pour les clients à faible latence (p. ex. à la maison), transcoder les flux en direct au lieu de les remultiplexer.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à faible latence (p. ex. à la maison), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Pour les clients à latence élevée (p. ex. connexions cellulaires), transcoder les flux en direct au lieu de les remultiplexer.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à latence élevée (p. ex. cellulaires), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de haute qualité du contrôleur Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de basse qualité du contrôleur Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recadrer le flux vidéo de la caméra. Activer cette option force aussi le transcodage des flux en direct.",
    "Left offset of the crop window, as a percentage of the original image width.": "Décalage gauche de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
    "Top offset of the crop window, as a percentage of the original image height.": "Décalage haut de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
    "Width of the crop window, as a percentage of original image width.": "Largeur de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
    "Height of the crop window, as a percentage of original image height.": "Hauteur de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
    "Enable higher quality snapshots.": "Activer des instantanés de meilleure qualité.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Utiliser le voyant d'état de la caméra pour signaler l'enregistrement d'un événement HKSV.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Ajouter un accessoire interrupteur pour activer ou désactiver l'enregistrement des événements HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de haute qualité du contrôleur Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de basse qualité du contrôleur Protect.",
    "Controllers": "Contrôleurs",
    "Another controller": "Un autre contrôleur",
    "No controller yet": "Aucun contrôleur pour l'instant",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Ajouter des accessoires trouve les consoles UniFi du réseau, ou l'une par son adresse, et s'y connecte avec un compte local.",
    "Settings": "Réglages",
    "Third-party camera": "Caméra tierce",
    "Copy": "Copier",
    "Find a camera's URLs": "Trouver les URL d'une caméra",
    "A third-party camera adopted in Protect streams from its own URLs. Homeswift asks the camera for them over ONVIF; put the ones you pick in the camera's Settings.": "Une caméra tierce adoptée dans Protect diffuse depuis ses propres URL. Homeswift les demande à la caméra par ONVIF ; mettez celles que vous choisissez dans les Réglages de la caméra."
  },
  "es": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Gestiona tus cámaras y dispositivos UniFi Protect en HomeKit.",
    "Support": "Soporte",
    "Cancel": "Cancelar",
    "Controller": "Controlador",
    "Username": "Nombre de usuario",
    "Password": "Contraseña",
    "Feature options": "Opciones de funciones",
    "Back": "Atrás",
    "Scope": "Ámbito",
    "Global": "Global",
    "All devices": "Todos los dispositivos",
    "Device": "Dispositivo",
    "Model": "Modelo",
    "Status": "Estado",
    "IP address": "Dirección IP",
    "e.g. 192.168.1.50": "p. ej., 192.168.1.50",
    "ONVIF port": "Puerto ONVIF",
    "(optional)": "(opcional)",
    "auto": "auto",
    "Service path": "Ruta del servicio",
    "(optional, /onvif/device_service by default)": "(opcional, /onvif/device_service de forma predeterminada)",
    "Discover URLs": "Descubrir las URL",
    "Stream preview": "Vista previa del flujo",
    "No preview": "Sin vista previa",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directa",
    "Direct snapshot URL": "URL directa de instantánea",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca de este plugin",
    "The Homeswift port of": "La adaptación para Homeswift de",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "Su documentación sirve aquí: las opciones, las opciones de funciones y los temas MQTT son los mismos.",
    "Getting started": "Primeros pasos",
    "Install, configure and connect to HomeKit.": "Instalar, configurar y conectar a HomeKit.",
    "Options for a controller or a device.": "Opciones para un controlador o un dispositivo.",
    "How to configure MQTT support.": "Cómo configurar la compatibilidad con MQTT.",
    "How-to guides": "Guías prácticas",
    "Doorbells": "Timbres",
    "Two-way audio, ring events and LCD messages.": "Audio bidireccional, eventos de llamada y mensajes LCD.",
    "HKSV with Protect cameras.": "HKSV con cámaras Protect.",
    "Liveview scenes": "Escenas Liveview",
    "Motion detection scenes and the security system.": "Escenas de detección de movimiento y el sistema de seguridad.",
    "Troubleshooting": "Solución de problemas",
    "Login, network and video problems.": "Problemas de inicio de sesión, red y vídeo.",
    "Checking": "Comprobando",
    "Devices": "Dispositivos",
    "Events": "Eventos",
    "Live": "En directo",
    "Every 2 minutes": "Cada 2 minutos",
    "Certificate": "Certificado",
    "Verified": "Verificado",
    "Pinned": "Fijado",
    "Not yet seen": "Aún no visto",
    "Connected": "Conectado",
    "Not connected yet: see the log.": "Aún no conectado: consulta el registro.",
    "Not running": "Detenido",
    "Actions for {name}": "Acciones de {name}",
    "Edit": "Editar",
    "Remove": "Eliminar",
    "Online": "En línea",
    "Offline": "Sin conexión",
    "Unknown": "Desconocido",
    "Select": "Elegir",
    "Cameras": "Cámaras",
    "Chimes": "Carillones",
    "Lights": "Luces",
    "Sensors": "Sensores",
    "Viewers": "Visores",
    "Camera": "Cámara",
    "Intermediate": "Intermedio",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "millisecond": "milisegundo",
    "milliseconds": "milisegundos",
    "decibel": "decibelio",
    "decibels": "decibelios",
    "Hertz": "hercios",
    "kilobits per second": "kilobits por segundo",
    "percentage": "porcentaje",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "none": "ninguno",
    "IP address and username are required.": "La dirección IP y el nombre de usuario son obligatorios.",
    "Discovering…": "Descubriendo…",
    "Discovery failed: {error}": "Error en el descubrimiento: {error}",
    "unknown error": "error desconocido",
    "Camera did not return any URLs.": "La cámara no ha devuelto ninguna URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "Se han encontrado {n} perfiles en el puerto {port}. Elige el que quieras usar.",
    "Discovered URLs on port {port}.": "URL descubiertas en el puerto {port}.",
    "Profile {n}": "Perfil {n}",
    "this camera": "esta cámara",
    "this chime": "este carillón",
    "this device": "este dispositivo",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Se ha agotado el tiempo tras {0} s esperando la respuesta de {1}. Comprueba que la dirección y las credenciales son correctas y que el controlador es accesible desde este equipo de Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0}: error de la API: credenciales de acceso no válidas. Revisa tu usuario y tu contraseña.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0}: error de la API: privilegios insuficientes para este usuario. Revisa los roles asignados a este usuario y asegúrate de que tiene privilegios suficientes.",
    "{0}: API error: Connection refused.": "{0}: error de la API: conexión rechazada.",
    "{0}: API error: Connection timed out.": "{0}: error de la API: se ha agotado el tiempo de conexión.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0}: error de la API: no se ha encontrado el nombre de host o la dirección IP: {1}. Comprueba que la dirección configurada para este controlador UniFi Protect es correcta.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0}: error de la API: no se puede conectar con el controlador Protect. Es temporal y puede ocurrir mientras se reinician los dispositivos.",
    "Invalid address.": "Dirección no válida.",
    "Unable to resolve {0}.": "No se puede resolver {0}.",
    "Connections to {0} are not permitted.": "No se permiten conexiones a {0}.",
    "ONVIF request timed out": "Se ha agotado el tiempo de espera de la solicitud ONVIF",
    "host and username are required.": "el host y el nombre de usuario son obligatorios.",
    "No reachable ONVIF service on {0} ({1}).": "No hay ningún servicio ONVIF accesible en {0} ({1}).",
    "Camera did not return a Media service capability.": "La cámara no ha devuelto ningún servicio Media.",
    "Camera did not return a Media service XAddr.": "La cámara no ha devuelto el XAddr del servicio Media.",
    "Camera returned no media profiles.": "La cámara no ha devuelto ningún perfil multimedia.",
    "The camera advertised its media service on a different host. Using {0} instead.": "La cámara anuncia su servicio multimedia en otro host. Se usa {0} en su lugar.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "La cámara ha devuelto URL de flujo o de instantánea en un host distinto de {0}. No se han añadido las credenciales a esas URL.",
    "Audio": "Audio",
    "Doorbell": "Timbre",
    "Logging": "Registro",
    "Motion": "Movimiento",
    "Security System": "Sistema de seguridad",
    "Sensor": "Sensor",
    "Video": "Vídeo",
    "Audio support.": "Compatibilidad con audio.",
    "Audio filter for ambient noise suppression.": "Filtro de audio para suprimir el ruido ambiente.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nivel de reducción de ruido, en decibelios, para el filtro afftdn de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frecuencia, en hercios, para el filtro highpass de FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frecuencia, en hercios, para el filtro lowpass de FFmpeg.",
    "Two-way audio support on supported cameras.": "Audio bidireccional en las cámaras compatibles.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar el audio bidireccional directamente a las cámaras compatibles, sin pasar por el controlador. Útil para sortear errores de algunas versiones del firmware de los controladores Protect.",
    "Make this device available in HomeKit.": "Hacer que este dispositivo esté disponible en HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Activar la luz indicadora de estado de este dispositivo en HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Añadir un accesorio interruptor para controlar la luz indicadora de estado en HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Activar la luz indicadora de visión nocturna de este dispositivo en HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Añadir un accesorio regulador para controlar la visión nocturna en HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Convertir este dispositivo en un dispositivo independiente en HomeKit, que habrá que añadir a HomeKit desde la app Casa.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Intentar reiniciar los dispositivos que fallan. Siempre se hace con mucha prudencia y solo tras periodos prolongados de problemas propios del dispositivo.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar el nombre de UniFi Protect de este dispositivo con HomeKit. La sincronización es solo en un sentido: el nombre pasa de UniFi Protect a HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Añadir un sensor de contacto que se activa cuando una huella dactilar o un NFC se autentica en un timbre Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Añadir un accesorio interruptor para elegir si HomeKit suena cuando se pulsa el timbre.",
    "Enable the doorbell messages feature.": "Activar la función de mensajes del timbre.",
    "Use messages saved to the Protect NVR as message switches.": "Usar los mensajes guardados en el NVR Protect como interruptores de mensaje.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Añadir un accesorio regulador para controlar el volumen del carillón Protect en HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Añadir accesorios interruptores para controlar los carillones físicos conectados a un timbre Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duración del sonido, en milisegundos, de un carillón físico digital conectado a un timbre Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Añadir un accesorio de luz para controlar la linterna de la cámara de paquetes de un timbre Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Añadir un accesorio interruptor para activar eventos de llamada en una cámara o un timbre Protect.",
    "Log doorbell ring events in Homebridge.": "Registrar los eventos de llamada del timbre en Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Registrar los eventos de grabación de HomeKit Secure Video en Homebridge.",
    "Log motion events in Homebridge.": "Registrar los eventos de movimiento en Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Duración, en segundos, de un evento de movimiento antes de permitir uno nuevo.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Añadir un accesorio sensor de ocupación que usa la actividad del sensor de movimiento para determinar la ocupación. De forma predeterminada, cualquier movimiento activa la ocupación. Si la opción de detección inteligente está activada, se usa en su lugar.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duración, en segundos, que se espera sin recibir eventos de movimiento para considerar que ya no hay ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de animales de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de caras de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de matrículas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de paquetes de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de personas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de vehículos de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de llanto de bebé de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de ladridos de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de coche de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de cláxones de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de CO de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de rotura de cristales de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de sirenas de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de humo de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de voz de UniFi Protect para activar la ocupación.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Al usar a la vez las opciones de sensor de ocupación y detección inteligente, utilizar la detección de audio de alarmas de CO y humo de UniFi Protect para activar la ocupación.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar la detección inteligente de UniFi Protect para los eventos de movimiento de HomeKit en un dispositivo compatible.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Añadir sensores de contacto para cada tipo de objeto de detección inteligente que admite UniFi Protect.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Añadir un accesorio sensor de contacto que corresponde a una matrícula concreta detectada por UniFi Protect. Puedes indicar varias matrículas separándolas con guiones (p. ej., MATRICULA1-MATRICULA2-MATRICULA3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Añadir un accesorio interruptor para activar o desactivar la detección de movimiento en HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Añadir un accesorio interruptor para activar manualmente un evento de detección de movimiento en HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publicar una lista M3U de las cámaras Protect en el puerto indicado de este servidor Homebridge, apta para apps (p. ej., Channels DVR) que pueden ofrecer las transmisiones en directo de las cámaras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Retardo, en segundos, antes de eliminar los dispositivos que ya no se detectan en el controlador Protect. Si está desactivado, los dispositivos se eliminan en tiempo real cuando lo hace el controlador Protect.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar en MQTT toda la telemetría en tiempo real recibida del controlador Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Añadir accesorios interruptores para controlar la grabación nativa del NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Añadir accesorios sensores para mostrar la información del sistema del controlador Protect (por ahora, solo la temperatura).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Añadir un accesorio interruptor para activar el accesorio sistema de seguridad, al usar la opción liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Mostrar el sensor de fugas Protect como sensor de contacto en lugar de sensor de fugas. Es útil para las automatizaciones, ya que los sensores de contacto de HomeKit ofrecen más opciones de automatización que los sensores de fugas, pensados sobre todo para alertas.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Añadir un accesorio cerradura para desbloquear. Por ahora, Protect solo permite desbloquear lectores Access con cámara en el mismo controlador que Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar la transcodificación acelerada por hardware cuando esté disponible (Mac de Apple, CPU Intel con Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Usar la API nativa de transmisión en directo de Protect para ver las transmisiones en directo.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Al transmitir a clientes de baja latencia (p. ej., en casa), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de baja latencia (p. ej., en casa), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Al transmitir a clientes de alta latencia (p. ej., conexiones móviles), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de alta latencia (p. ej., móviles), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de alta calidad del controlador Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de media calidad del controlador Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de baja calidad del controlador Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar el flujo de vídeo de la cámara. Activar esta opción también fuerza la transcodificación de las transmisiones en directo.",
    "Left offset of the crop window, as a percentage of the original image width.": "Desplazamiento izquierdo del recorte, como porcentaje del ancho de la imagen original.",
    "Top offset of the crop window, as a percentage of the original image height.": "Desplazamiento superior del recorte, como porcentaje del alto de la imagen original.",
    "Width of the crop window, as a percentage of original image width.": "Ancho del recorte, como porcentaje del ancho de la imagen original.",
    "Height of the crop window, as a percentage of original image height.": "Alto del recorte, como porcentaje del alto de la imagen original.",
    "Enable higher quality snapshots.": "Activar instantáneas de mayor calidad.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar la luz indicadora de estado de la cámara para mostrar cuándo se graba un evento HKSV.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Añadir un accesorio interruptor para activar o desactivar la grabación de eventos HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de alta calidad del controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de media calidad del controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de baja calidad del controlador Protect.",
    "Controllers": "Controladores",
    "Another controller": "Otro controlador",
    "No controller yet": "Todavía no hay ningún controlador",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Añadir accesorios encuentra las consolas UniFi de la red, o una por su dirección, e inicia sesión en ella con una cuenta local.",
    "Settings": "Ajustes",
    "Third-party camera": "Cámara de terceros",
    "Copy": "Copiar",
    "Find a camera's URLs": "Buscar las URL de una cámara",
    "A third-party camera adopted in Protect streams from its own URLs. Homeswift asks the camera for them over ONVIF; put the ones you pick in the camera's Settings.": "Una cámara de terceros adoptada en Protect emite desde sus propias URL. Homeswift se las pide a la cámara por ONVIF; pon las que elijas en los Ajustes de la cámara."
  },
  "pt": {
    "Manage your UniFi Protect cameras and devices in HomeKit.": "Faça a gestão das câmaras e dispositivos UniFi Protect no HomeKit.",
    "Support": "Suporte",
    "Cancel": "Cancelar",
    "Controller": "Controlador",
    "Username": "Nome de utilizador",
    "Password": "Palavra-passe",
    "Feature options": "Opções de funcionalidades",
    "Back": "Voltar",
    "Scope": "Âmbito",
    "Global": "Global",
    "All devices": "Todos os dispositivos",
    "Device": "Dispositivo",
    "Model": "Modelo",
    "Status": "Estado",
    "IP address": "Endereço IP",
    "e.g. 192.168.1.50": "p. ex. 192.168.1.50",
    "ONVIF port": "Porta ONVIF",
    "(optional)": "(opcional)",
    "auto": "auto",
    "Service path": "Caminho do serviço",
    "(optional, /onvif/device_service by default)": "(opcional, /onvif/device_service por predefinição)",
    "Discover URLs": "Descobrir os URL",
    "Stream preview": "Pré-visualização do fluxo",
    "No preview": "Sem pré-visualização",
    "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS direto",
    "Direct snapshot URL": "URL direto de instantâneo",
    "Discard": "Descartar",
    "Save": "Guardar",
    "About this plugin": "Acerca deste plugin",
    "The Homeswift port of": "A adaptação para Homeswift do",
    "Its documentation applies here: the options, feature options and MQTT topics are the same.": "A sua documentação aplica-se aqui: as opções, as opções de funcionalidades e os tópicos MQTT são os mesmos.",
    "Getting started": "Primeiros passos",
    "Install, configure and connect to HomeKit.": "Instalar, configurar e ligar ao HomeKit.",
    "Options for a controller or a device.": "Opções para um controlador ou um dispositivo.",
    "How to configure MQTT support.": "Como configurar o suporte de MQTT.",
    "How-to guides": "Guias práticos",
    "Doorbells": "Campainhas",
    "Two-way audio, ring events and LCD messages.": "Áudio bidirecional, eventos de toque e mensagens LCD.",
    "HKSV with Protect cameras.": "HKSV com câmaras Protect.",
    "Liveview scenes": "Cenas Liveview",
    "Motion detection scenes and the security system.": "Cenas de deteção de movimento e o sistema de segurança.",
    "Troubleshooting": "Resolução de problemas",
    "Login, network and video problems.": "Problemas de início de sessão, rede e vídeo.",
    "Checking": "A verificar",
    "Devices": "Dispositivos",
    "Events": "Eventos",
    "Live": "Em direto",
    "Every 2 minutes": "A cada 2 minutos",
    "Certificate": "Certificado",
    "Verified": "Verificado",
    "Pinned": "Fixado",
    "Not yet seen": "Ainda não visto",
    "Connected": "Ligado",
    "Not connected yet: see the log.": "Ainda não ligado: consulte o registo.",
    "Not running": "Parado",
    "Actions for {name}": "Ações de {name}",
    "Edit": "Editar",
    "Remove": "Remover",
    "Online": "Online",
    "Offline": "Offline",
    "Unknown": "Desconhecido",
    "Select": "Escolher",
    "Cameras": "Câmaras",
    "Chimes": "Carrilhões",
    "Lights": "Luzes",
    "Sensors": "Sensores",
    "Viewers": "Visores",
    "Camera": "Câmara",
    "Intermediate": "Intermédio",
    "second": "segundo",
    "seconds": "segundos",
    "minute": "minuto",
    "minutes": "minutos",
    "hour": "hora",
    "hours": "horas",
    "millisecond": "milissegundo",
    "milliseconds": "milissegundos",
    "decibel": "decibel",
    "decibels": "decibéis",
    "Hertz": "hertz",
    "kilobits per second": "kilobits por segundo",
    "percentage": "percentagem",
    "global": "global",
    "controller": "controlador",
    "device": "dispositivo",
    "none": "nenhum",
    "IP address and username are required.": "O endereço IP e o nome de utilizador são obrigatórios.",
    "Discovering…": "A descobrir…",
    "Discovery failed: {error}": "A descoberta falhou: {error}",
    "unknown error": "erro desconhecido",
    "Camera did not return any URLs.": "A câmara não devolveu nenhum URL.",
    "Found {n} profiles on port {port}. Pick the one to use.": "Foram encontrados {n} perfis na porta {port}. Escolha o que pretende usar.",
    "Discovered URLs on port {port}.": "URL descobertos na porta {port}.",
    "Profile {n}": "Perfil {n}",
    "this camera": "esta câmara",
    "this chime": "este carrilhão",
    "this device": "este dispositivo",
    "Timed out after {0}s waiting for {1} to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host.": "Tempo esgotado após {0} s à espera de resposta de {1}. Verifique se o endereço e as credenciais estão corretos e se o controlador está acessível a partir deste computador Homeswift.",
    "{0}: API error: Invalid login credentials given. Please check your login and password.": "{0}: erro da API: credenciais de acesso inválidas. Verifique o nome de utilizador e a palavra-passe.",
    "{0}: API error: Insufficient privileges for this user. Please check the roles assigned to this user and ensure it has sufficient privileges.": "{0}: erro da API: privilégios insuficientes para este utilizador. Verifique as funções atribuídas a este utilizador e confirme que tem privilégios suficientes.",
    "{0}: API error: Connection refused.": "{0}: erro da API: ligação recusada.",
    "{0}: API error: Connection timed out.": "{0}: erro da API: a ligação expirou.",
    "{0}: API error: Hostname or IP address not found: {1}. Please ensure the address you configured for this UniFi Protect controller is correct.": "{0}: erro da API: nome do anfitrião ou endereço IP não encontrado: {1}. Confirme que o endereço configurado para este controlador UniFi Protect está correto.",
    "{0}: API error: Unable to connect to the Protect controller. This is temporary and may occur during device reboots.": "{0}: erro da API: não é possível ligar ao controlador Protect. É temporário e pode acontecer durante o reinício dos dispositivos.",
    "Invalid address.": "Endereço inválido.",
    "Unable to resolve {0}.": "Não é possível resolver {0}.",
    "Connections to {0} are not permitted.": "Não são permitidas ligações a {0}.",
    "ONVIF request timed out": "O pedido ONVIF expirou",
    "host and username are required.": "o anfitrião e o nome de utilizador são obrigatórios.",
    "No reachable ONVIF service on {0} ({1}).": "Nenhum serviço ONVIF acessível em {0} ({1}).",
    "Camera did not return a Media service capability.": "A câmara não devolveu nenhum serviço Media.",
    "Camera did not return a Media service XAddr.": "A câmara não devolveu o XAddr do serviço Media.",
    "Camera returned no media profiles.": "A câmara não devolveu nenhum perfil multimédia.",
    "The camera advertised its media service on a different host. Using {0} instead.": "A câmara anuncia o serviço multimédia noutro anfitrião. É usado {0} em vez disso.",
    "The camera returned stream or snapshot URLs on a different host than {0}. Credentials were not added to those URLs.": "A câmara devolveu URL de fluxo ou de instantâneo num anfitrião diferente de {0}. As credenciais não foram adicionadas a esses URL.",
    "Audio": "Áudio",
    "Doorbell": "Campainha",
    "Logging": "Registo",
    "Motion": "Movimento",
    "Security System": "Sistema de segurança",
    "Sensor": "Sensor",
    "Video": "Vídeo",
    "Audio support.": "Suporte de áudio.",
    "Audio filter for ambient noise suppression.": "Filtro de áudio para suprimir o ruído ambiente.",
    "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nível de redução de ruído, em decibéis, para o filtro afftdn do FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frequência, em hertz, para o filtro highpass do FFmpeg.",
    "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frequência, em hertz, para o filtro lowpass do FFmpeg.",
    "Two-way audio support on supported cameras.": "Áudio bidirecional nas câmaras compatíveis.",
    "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar o áudio bidirecional diretamente para as câmaras compatíveis, sem passar pelo controlador. Útil para contornar erros de algumas versões do firmware dos controladores Protect.",
    "Make this device available in HomeKit.": "Disponibilizar este dispositivo no HomeKit.",
    "Enable the status indicator light for this device in HomeKit.": "Ativar a luz indicadora de estado deste dispositivo no HomeKit.",
    "Add a switch accessory to control the status indicator light in HomeKit.": "Adicionar um acessório interruptor para controlar a luz indicadora de estado no HomeKit.",
    "Enable the night vision indicator light for this device in HomeKit.": "Ativar a luz indicadora de visão noturna deste dispositivo no HomeKit.",
    "Add a dimmer accessory to control the night vision state in HomeKit.": "Adicionar um acessório regulador para controlar a visão noturna no HomeKit.",
    "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Tornar este dispositivo independente no HomeKit, sendo necessário adicioná-lo ao HomeKit através da app Casa.",
    "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tentar reiniciar os dispositivos com falhas. Isto é sempre feito com muita prudência e apenas após períodos prolongados de problemas específicos do dispositivo.",
    "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar o nome UniFi Protect deste dispositivo com o HomeKit. A sincronização é apenas num sentido: o nome passa do UniFi Protect para o HomeKit.",
    "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Adicionar um sensor de contacto que é ativado quando uma impressão digital ou um NFC é autenticado numa campainha Protect.",
    "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Adicionar um acessório interruptor para escolher se o HomeKit toca quando a campainha é premida.",
    "Enable the doorbell messages feature.": "Ativar a funcionalidade de mensagens da campainha.",
    "Use messages saved to the Protect NVR as message switches.": "Usar as mensagens guardadas no NVR Protect como interruptores de mensagem.",
    "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Adicionar um acessório regulador para controlar o volume do carrilhão Protect no HomeKit.",
    "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Adicionar acessórios interruptores para controlar os carrilhões físicos ligados a uma campainha Protect.",
    "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duração do toque, em milissegundos, de um carrilhão físico digital ligado a uma campainha Protect.",
    "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Adicionar um acessório de luz para controlar a lanterna da câmara de encomendas de uma campainha Protect.",
    "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Adicionar um acessório interruptor para acionar eventos de toque numa câmara ou campainha Protect.",
    "Log doorbell ring events in Homebridge.": "Registar os eventos de toque da campainha no Homebridge.",
    "Log HomeKit Secure Video recording events in Homebridge.": "Registar os eventos de gravação do HomeKit Secure Video no Homebridge.",
    "Log motion events in Homebridge.": "Registar os eventos de movimento no Homebridge.",
    "Duration, in seconds, of a single motion event, before allowing a new one.": "Duração, em segundos, de um evento de movimento antes de permitir um novo.",
    "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Adicionar um acessório sensor de ocupação que usa a atividade do sensor de movimento para determinar a ocupação. Por predefinição, qualquer movimento ativa a ocupação. Se a opção de deteção inteligente estiver ativada, é usada em vez disso.",
    "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duração, em segundos, a aguardar sem receber eventos de movimento para considerar que a ocupação deixou de ser detetada.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's animal detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de animais do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's face detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de rostos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's license plate detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de matrículas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's package detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de encomendas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's person detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de pessoas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's vehicle detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de veículos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's baby crying audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de choro de bebé do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's bark audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de latidos do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de carro do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's car horn audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de buzinas do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de CO do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's glass break audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de quebra de vidros do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's siren audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de sirenes do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's smoke alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de fumo do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's speaking audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de fala do UniFi Protect para ativar a ocupação.",
    "When using both the occupancy sensor and smart detection feature options, use UniFi Protect's CO and smoke alarm audio detection to trigger occupancy.": "Ao usar em conjunto as opções de sensor de ocupação e deteção inteligente, usar a deteção de áudio de alarmes de CO e fumo do UniFi Protect para ativar a ocupação.",
    "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar a deteção inteligente do UniFi Protect para os eventos de movimento do HomeKit num dispositivo compatível.",
    "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Adicionar sensores de contacto para cada tipo de objeto da deteção inteligente suportado pelo UniFi Protect.",
    "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Adicionar um acessório sensor de contacto que corresponde a uma matrícula específica detetada pelo UniFi Protect. É possível indicar várias matrículas separando-as com hífenes (p. ex. MATRICULA1-MATRICULA2-MATRICULA3).",
    "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Adicionar um acessório interruptor para ativar ou desativar a deteção de movimento no HomeKit.",
    "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Adicionar um acessório interruptor para acionar manualmente um evento de deteção de movimento no HomeKit.",
    "Publish an M3U playlist of Protect cameras on the specified port of this Homebridge server that is suitable for use in apps (e.g. Channels DVR) that can make camera livestreams available through them.": "Publicar uma lista M3U das câmaras Protect na porta indicada deste servidor Homebridge, adequada para apps (p. ex. Channels DVR) que conseguem disponibilizar as transmissões em direto das câmaras.",
    "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Atraso, em segundos, antes de remover os dispositivos que deixaram de ser detetados no controlador Protect. Se estiver desativado, os dispositivos são removidos em tempo real quando o controlador Protect o faz.",
    "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar no MQTT toda a telemetria em tempo real recebida do controlador Protect.",
    "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Adicionar acessórios interruptores para controlar a gravação nativa do NVR UniFi Protect.",
    "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Adicionar acessórios sensores para mostrar as informações do sistema do controlador Protect (por agora, apenas a temperatura).",
    "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Adicionar um acessório interruptor para acionar o acessório sistema de segurança, ao usar a opção liveview.",
    "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Apresentar o sensor de fugas Protect como sensor de contacto em vez de sensor de fugas. É útil para automatizações, porque os sensores de contacto do HomeKit oferecem mais opções de automatização do que os sensores de fugas, pensados sobretudo para alertas.",
    "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Adicionar um acessório fechadura para destrancar. Por agora, o Protect só permite destrancar leitores Access com câmara no mesmo controlador que o Protect.",
    "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar a transcodificação acelerada por hardware quando disponível (Mac da Apple, CPU Intel com Quick Sync Video, Raspberry Pi 4).",
    "Use the native Protect livestream API to view livestreams.": "Usar a API nativa de transmissão em direto do Protect para ver as transmissões em direto.",
    "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Ao transmitir para clientes de baixa latência (p. ex. em casa), transcodificar as transmissões em direto em vez de as remultiplexar.",
    "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de baixa latência (p. ex. em casa), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
    "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Ao transmitir para clientes de alta latência (p. ex. ligações móveis), transcodificar as transmissões em direto em vez de as remultiplexar.",
    "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de alta latência (p. ex. móveis), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
    "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
    "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
    "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de baixa qualidade do controlador Protect.",
    "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar o fluxo de vídeo da câmara. Ativar esta opção também força a transcodificação das transmissões em direto.",
    "Left offset of the crop window, as a percentage of the original image width.": "Deslocamento esquerdo da área de recorte, em percentagem da largura da imagem original.",
    "Top offset of the crop window, as a percentage of the original image height.": "Deslocamento superior da área de recorte, em percentagem da altura da imagem original.",
    "Width of the crop window, as a percentage of original image width.": "Largura da área de recorte, em percentagem da largura da imagem original.",
    "Height of the crop window, as a percentage of original image height.": "Altura da área de recorte, em percentagem da altura da imagem original.",
    "Enable higher quality snapshots.": "Ativar instantâneos de maior qualidade.",
    "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar a luz indicadora de estado da câmara para mostrar quando um evento HKSV está a ser gravado.",
    "Add a switch accessory to enable or disable HKSV event recording.": "Adicionar um acessório interruptor para ativar ou desativar a gravação de eventos HKSV.",
    "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
    "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de baixa qualidade do controlador Protect.",
    "Controllers": "Controladores",
    "Another controller": "Outro controlador",
    "No controller yet": "Ainda sem controlador",
    "Add accessories finds the UniFi consoles on the network, or one by its address, and signs in to it with a local account.": "Adicionar acessórios encontra as consolas UniFi da rede, ou uma pelo seu endereço, e inicia sessão nela com uma conta local.",
    "Settings": "Definições",
    "Third-party camera": "Câmara de terceiros",
    "Copy": "Copiar",
    "Find a camera's URLs": "Encontrar os URL de uma câmara",
    "A third-party camera adopted in Protect streams from its own URLs. Homeswift asks the camera for them over ONVIF; put the ones you pick in the camera's Settings.": "Uma câmara de terceiros adotada no Protect transmite a partir dos seus próprios URL. O Homeswift pede-os à câmara por ONVIF; ponha os que escolher nas Definições da câmara."
  }
});

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UniFi Protect</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<link rel="stylesheet" href="protect.css">
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large accessory" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3" y="6" width="13" height="12" rx="3"/><path d="M16 10.5l5-3v9l-5-3z"/></svg></span>
    <div>
      <h1>UniFi Protect</h1>
      <p class="muted" data-i18n>Manage your UniFi Protect cameras and devices in HomeKit.</p>
    </div>
  </div>

  <!-- The controllers the instance runs, with their devices; Setup adds others. -->
  <section id="controllersScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Controllers</h2></div>
    <div id="controllersList" class="controllers"></div>
    <div class="actions">
      <button id="onvifBtn" data-i18n data-action-icon="search">Find a camera's URLs</button>
      <button id="supportBtn" data-i18n data-action-icon="link">Support</button>
    </div>
  </section>

  <!-- A third-party camera's RTSP and snapshot URLs, found over ONVIF, for its Settings. -->
  <section id="onvifScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Find a camera's URLs</h2><button id="backFromOnvifBtn" class="link" data-i18n data-action-icon="restore">Back</button></div>
    <div class="card">
      <p class="muted" data-i18n>A third-party camera adopted in Protect streams from its own URLs. Homeswift asks the camera for them over ONVIF; put the ones you pick in the camera's Settings.</p>
      <div class="form-grid">
        <label class="field"><span class="field-title" data-i18n>IP address</span><input id="onvifHost" type="text" placeholder="e.g. 192.168.1.50" autocomplete="off" spellcheck="false" data-i18n></label>
        <label class="field"><span class="field-title" data-i18n>ONVIF port <span class="muted" data-i18n>(optional)</span></span><input id="onvifPort" type="number" placeholder="auto" min="1" max="65535" data-i18n></label>
        <label class="field"><span class="field-title" data-i18n>Username</span><input id="onvifUser" type="text" autocomplete="off" spellcheck="false"></label>
        <label class="field"><span class="field-title" data-i18n>Password</span><input id="onvifPass" type="password" autocomplete="off"></label>
        <label class="field wide"><span class="field-title" data-i18n>Service path <span class="muted" data-i18n>(optional, /onvif/device_service by default)</span></span><input id="onvifPath" type="text" placeholder="/onvif/device_service" autocomplete="off" spellcheck="false"></label>
      </div>
      <div class="row-actions"><span id="onvifStatus" class="status-line"></span><button id="onvifDiscoverBtn" class="primary" type="button" data-i18n data-action-icon="search">Discover URLs</button></div>
      <div id="onvifAssistant"></div>
      <div id="onvifProfiles" class="found"></div>
    </div>
  </section>

  <!-- Support. -->
  <section id="supportScreen" class="screen hidden">
    <div class="section-head"><h2 data-i18n>Support</h2><button id="backFromSupportBtn" class="link" data-i18n data-action-icon="restore">Back</button></div>
    <div class="card support">
      <h3 data-i18n>About this plugin</h3>
      <p><span data-i18n>The Homeswift port of</span> <a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect">homebridge-unifi-protect</a>. <span data-i18n>Its documentation applies here: the options, feature options and MQTT topics are the same.</span></p>
      <h3 data-i18n>Getting started</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/getting-started.md"><b data-i18n>Getting started</b></a><span class="muted" data-i18n>Install, configure and connect to HomeKit.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/feature-options.md"><b data-i18n>Feature options</b></a><span class="muted" data-i18n>Options for a controller or a device.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/mqtt.md"><b>MQTT</b></a><span class="muted" data-i18n>How to configure MQTT support.</span></li>
      </ul>
      <h3 data-i18n>How-to guides</h3>
      <ul class="links">
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/doorbell.md"><b data-i18n>Doorbells</b></a><span class="muted" data-i18n>Two-way audio, ring events and LCD messages.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/homekit-secure-video.md"><b>HomeKit Secure Video</b></a><span class="muted" data-i18n>HKSV with Protect cameras.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/liveviews.md"><b data-i18n>Liveview scenes</b></a><span class="muted" data-i18n>Motion detection scenes and the security system.</span></li>
        <li><a target="_blank" rel="noopener noreferrer" href="https://github.com/mp-consulting/homebridge-unifi-protect/blob/main/docs/troubleshooting.md"><b data-i18n>Troubleshooting</b></a><span class="muted" data-i18n>Login, network and video problems.</span></li>
      </ul>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="i18n.js"></script>
<script src="options.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
        "options.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The helpers of the Homebridge plugin's settings page that touch no element and that this page still uses (the ONVIF
// profiles of third-party-overrides.js, what may reach the Assistant, a device's problem), as window.ProtectOptions.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;

  /// Profiles with the same URLs are one stream: the one with the largest resolution stays.
  function dedupeProfilesByUrl(profiles) {
    const byKey = new Map();
    for (const profile of profiles) {
      const key = (profile.rtspUrl || "") + "|" + (profile.snapshotUrl || "");
      const existing = byKey.get(key);
      const pixels = (p) => (p?.resolution?.width ?? 0) * (p?.resolution?.height ?? 0);
      if (!existing || pixels(profile) > pixels(existing)) byKey.set(key, profile);
    }
    return [...byKey.values()];
  }

  function formatProfileLabel(profile, index) {
    const parts = [profile.name || t("Profile {n}", { n: index + 1 })];
    if (profile.resolution?.width && profile.resolution?.height) parts.push(profile.resolution.width + "×" + profile.resolution.height);
    if (profile.encoding) parts.push(profile.encoding);
    return parts.join(" — ");
  }

  // MARK: The Assistant: what may leave the page

  const ipv4 = /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b/g;
  const macPattern = /\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b/g;

  function scrubText(text, addresses = []) {
    let result = String(text ?? "");
    for (const address of addresses) {
      if (typeof address === "string" && address.trim()) result = result.split(address.trim()).join("[address]");
    }
    return result.replace(macPattern, "[MAC address]").replace(ipv4, "[IP address]");
  }

  window.ProtectOptions = { dedupeProfilesByUrl, formatProfileLabel, scrubText };
})();

"""#),
        "protect.css": WebFile(contentType: "text/css; charset=utf-8", body: #"""
/* The UniFi Protect page on the UI's materials: the controllers with their devices, a third-party camera's URLs found
   over ONVIF, and the support links, one screen at a time. Settings are edited on the Settings pages. */

.screen { animation: fade var(--normal) var(--ease-out); }
.actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-top: 14px; }
.row-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 14px; }
.row-actions .status-line { flex: 1; margin: 0; }
.form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px 16px; margin-top: 10px; }
.field.wide { grid-column: 1 / -1; }
.status-line.error { color: var(--error); }
.status-line.ok { color: var(--ok); }
.status-line.warn { color: var(--warn); }

.controllers { display: grid; gap: 12px; }
.controller { margin: 0; display: grid; gap: 10px; animation: materialize var(--normal) var(--ease-out); }
.controller-head { display: flex; align-items: center; gap: 12px; min-width: 0; flex-wrap: wrap; }
.controller-head .who { flex: 1; min-width: 0; }
.controller-head strong { display: block; font-size: 1.0625rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.controller-head .muted { font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.controller .facts { font-size: 0.8125rem; }

.found { display: grid; gap: 8px; margin-top: 14px; }
.found .item { display: flex; align-items: center; gap: 12px; margin: 0; padding: 10px 10px 10px 14px; text-align: left; width: 100%; }
.found .item div { flex: 1; min-width: 0; }
.found .item .muted { font-size: 0.8125rem; overflow-wrap: anywhere; }
.mono { font-family: var(--mono, ui-monospace, monospace); }

.thumb { width: 96px; height: 54px; flex: none; border-radius: 10px; overflow: hidden; display: grid; place-items: center; background: var(--material-thin); border: 1px solid var(--line); font-size: 0.6875rem; }
.thumb img { width: 100%; height: 100%; object-fit: cover; }

.support h3 { margin: 18px 0 8px; }
.support h3:first-child { margin-top: 0; }
.links { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.links li { display: grid; padding: 8px 12px; border-radius: 12px; background: var(--material-thin); }
.links a { color: var(--accent); text-decoration: none; }

@media (prefers-reduced-motion: reduce) { .screen, .controller { animation: none; } }
@media (max-width: 760px) { .form-grid { grid-template-columns: 1fr; } }

"""#),
    ]
}
