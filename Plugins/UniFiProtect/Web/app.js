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

  const pluginSettings = `/plugins/${location.pathname.split("/")[2] || ""}/settings`;
  const settingsOf = (mac) => `${pluginSettings}?accessory=${encodeURIComponent(`UniFi Protect:${String(mac).replace(/[:-]/g, "").toUpperCase()}`)}`;

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
    const copy = () => navigator.clipboard?.writeText([profile.rtspUrl, profile.snapshotUrl].filter(Boolean).join("\n"));
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
