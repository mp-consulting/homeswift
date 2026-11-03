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
