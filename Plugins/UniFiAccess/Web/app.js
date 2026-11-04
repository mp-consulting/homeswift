// The UniFi Access page: the controllers this instance runs, each with its status and its hubs and readers, and where
// to set up another (Add accessories, which signs in to it). It writes no settings
// (docs/adr/0002-schema-declares-every-setting.md): a controller's, a device's and the plugin's open the Settings pages.
(() => {
  "use strict";
  const { $, el, request, explain, breadcrumb, setupCard } = homeswift;
  const { t, tn } = HomeswiftI18n;

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

  // MARK: Where settings are edited: the plugin's Settings page, and each controller's or device's there.

  const settingsOf = (deviceID) => homeswift.accessorySettings(`UniFi Access:${String(deviceID).toUpperCase()}`);

  function show(id) {
    for (const screen of ["controllers-screen", "support-screen"]) $(`#${screen}`).classList.toggle("hidden", screen !== id);
    window.scrollTo({ top: 0, behavior: reducedMotion.matches ? "auto" : "smooth" });
  }

  // MARK: Controllers

  async function renderControllers() {
    const list = $("#controllers");
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

  function controllerCard(ctrl) {
    const status = el("span", { class: "pill status standby", text: t("Checking…") });
    const slot = el("div");
    const devices = ctrl.devices ?? [];
    const card = el("div", { class: "card controller" },
      el("div", { class: "controller-head" },
        el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("inputs")),
        el("div", { class: "who" }, el("strong", { text: ctrl.name || ctrl.address }), el("div", { class: "muted", text: ctrl.address })),
        status),
      slot,
      devices.length ? el("div", { class: "found" }, devices.map(deviceRow)) : null,
      el("div", { class: "card-foot" },
        el("span", { class: "muted", text: ctrl.connected ? tn("Connected · {n} device in HomeKit", "Connected · {n} devices in HomeKit", devices.length) : t("Not connected yet: see the log.") }),
        ctrl.mac ? el("a", { class: "button", href: settingsOf(ctrl.mac), actionIcon: "gear", text: t("Settings") }) : null));
    request("status", { method: "POST", body: { address: ctrl.address } }).then((result) => {
      status.className = `pill status ${result.online ? "on" : "away"}`;
      status.textContent = result.online ? t("Online") : t("Offline");
      if (!result.online) {
        slot.replaceChildren(explain({
          error: "The controller did not answer an HTTPS request on port 443 within 5 seconds (status check from the Homeswift server), so it is shown as Offline.",
          context: "The user is looking at the UniFi Access controllers the plugin runs in its page.",
          device: { name: ctrl.name, connected: ctrl.connected },
        }));
      }
    }).catch(() => {
      status.className = "pill status standby";
      status.textContent = t("Unknown");
    });
    return card;
  }

  /// A hub or a reader of a controller: its state, and its Settings.
  function deviceRow(device) {
    const state = [device.model, device.online ? t("Online") : t("Disconnected")];
    if (device.locked !== undefined) state.push(device.locked ? t("Locked") : t("Unlocked"));
    return el("div", { class: "card item" },
      el("span", { class: "tile accessory", "aria-hidden": "true" }, HomeswiftCommon.icon("lock")),
      el("div", {}, el("strong", { text: device.name }), el("div", { class: "muted", text: state.filter(Boolean).join(" · ") })),
      el("a", { class: "button", href: settingsOf(device.featureId), actionIcon: "gear", text: t("Settings") }));
  }

  $("#open-support").addEventListener("click", () => { show("support-screen"); breadcrumb(t("Support"), backToControllers); });
  $("#back-from-support").addEventListener("click", backToControllers);

  function backToControllers() {
    breadcrumb(null);
    show("controllers-screen");
    renderControllers();
  }

  // MARK: Sentences of the page with elements in them (links, code): the translation's {0}, {1}… are the
  // element's children, in order. The links have data-i18n for their own text.

  function sentence(node, text) {
    const parts = [...node.children];
    node.replaceChildren(...text.split(/\{(\d+)\}/).map((part, i) => (i % 2 ? parts[Number(part)] : part)));
  }
  sentence($("#support-about"), t("A port of {0} to {1}. If you find it useful, consider starring the projects on GitHub."));
  sentence($("#support-readme"), t("{0} in Homeswift, and what differs from Homebridge."));
  sentence($("#support-options"), t("{0}: what each setting of the plugin's and its devices' Settings was in the Homebridge plugin."));
  sentence($("#support-mqtt"), t("{0}: the topics published and accepted."));
  sentence($("#support-changelog"), t("{0} of the Homebridge plugin this one follows."));
  sentence($("#support-discord"), t("{0} of the UniFi plugins."));
  sentence($("#support-issues"), t("{0} for the Homebridge plugin's behaviour, or {1} for this port."));

  // MARK: Start

  show("controllers-screen");
  renderControllers();
})();
