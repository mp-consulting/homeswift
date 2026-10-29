// The eWeLink page, after the Homebridge plugin's settings UI: connect the account (or reuse the plugin's
// session), the account's devices with their LAN and RF details (an mDNS scan runs while the cloud answers),
// the connection settings, and saving them into this instance's block, which reloads the plugin. The session
// stays in the plugin: the browser never sees a token.
(() => {
  "use strict";
  const { t, tn } = HomeswiftI18n;
  const { $, el, request, name, explain, api, fact } = homeswift;
  /// The button busy while `work` runs; errors go to the caller.
  const act = (button, work) => homeswift.act(button, work, null);

  const steps = { login: $("#step-login"), devices: $("#step-devices"), complete: $("#step-complete") };
  const showStep = (step) => Object.entries(steps).forEach(([key, node]) => node.classList.toggle("hidden", key !== step));

  let devices = [];
  let region = null;
  let config = {};
  // Account fields typed in this page, saved with the settings.
  let pendingAccount = null;

  // MARK: config.json: this instance's block, read and written through the signed-in UI.

  async function readBlock() {
    config = (await homeswift.readBlock()) || {};
    return config;
  }

  // MARK: Problems, with the Assistant's explanation when it is set up

  /// What the Assistant may see: no credentials, tokens or IP addresses.
  const assistantContext = (extra) => [extra, `Connection mode: ${config.mode || "auto"}.`,
    config.countryCode ? `Account country code: ${config.countryCode}.` : "", region ? `API region: ${region}.` : ""].filter(Boolean).join(" ");

  function showProblem(container, message, context) {
    container.classList.remove("hidden");
    container.replaceChildren(el("p", { text: message }), explain({ error: message, context: assistantContext(context) }));
  }

  function clearProblem(container) {
    container.classList.add("hidden");
    container.replaceChildren();
  }

  /// Why a device needs attention, or null.
  function deviceProblem(device) {
    if (!device.online) return "The eWeLink cloud reports this device as offline.";
    if (device.lanEnabled && !device.lanIp) return "LAN control is enabled for this device, but it was not found on the local network (no IP address over mDNS).";
    return null;
  }

  // MARK: Devices

  function deviceRow(device) {
    const badges = [];
    if (device.isRfSubdevice) badges.push(el("span", { class: "pill rf", text: "RF" }));
    if (device.lanEnabled && device.lanIp) badges.push(el("span", { class: "pill lan", text: t("LAN: {address}", { address: device.lanIp }) }));
    else if (device.lanEnabled) badges.push(el("span", { class: "pill lan-warn", text: t("LAN: No IP") }));
    else badges.push(el("span", { class: "pill", text: t("Cloud") }));
    badges.push(el("span", { class: `pill status ${device.online ? "on" : "away"}`, text: device.online ? t("Online") : t("Offline") }));
    const problem = deviceProblem(device);
    return el("li", { class: `device ${device.isRfSubdevice ? "rf" : ""}` },
      el("div", { class: "info" },
        el("div", { class: "name", text: device.name }),
        el("div", { class: "meta" },
          el("span", { class: "mono", text: t("ID: {id}", { id: device.deviceId }) }),
          el("span", { text: t("{brand} — {model} (UIID: {uiid})", { brand: device.brand || t("Unknown"), model: device.model || t("Unknown"), uiid: device.uiid != null ? String(device.uiid) : t("N/A") }) })),
        device.buttons && device.buttons.length ? el("div", { class: "buttons" }, device.buttons.map((button) => el("span", { text: button }))) : null),
      el("div", { class: "badges" }, badges),
      problem ? explain({
        error: problem,
        context: assistantContext("The user is looking at the device list of the eWeLink plugin settings."),
        device: {
          name: device.name, deviceId: device.deviceId, brand: device.brand, model: device.model, uiid: device.uiid, online: !!device.online,
          lanEnabled: !!device.lanEnabled, lanAddressFound: !!device.lanIp, rfSubdevice: !!device.isRfSubdevice, parentDeviceId: device.parentDeviceId,
        },
      }) : null);
  }

  function renderDevices() {
    $("#device-count").textContent = String(devices.length);
    $("#devices").replaceChildren(...(devices.length ? devices.map(deviceRow)
      : [el("li", { class: "empty" }, el("p", { text: t("No devices found") }), el("p", { class: "muted", text: t("Connect your eWeLink account and click Refresh.") }))]));
  }

  async function loadDevices() {
    const button = $("#refresh");
    await act(button, async () => {
      clearProblem($("#devices-problem"));
      try {
        const answer = await request("devices");
        devices = answer.devices || [];
        renderDevices();
      } catch (e) {
        showProblem($("#devices-problem"), e.message || t("Failed to load devices"),
          "Loading the device list from the eWeLink cloud (plus a 3 second mDNS LAN scan) failed in the plugin settings.");
      }
    });
    await loadStatus();
  }

  async function loadStatus() {
    try {
      const status = await request("status");
      $("#status").replaceChildren(
        fact(t("Cloud"), status.websocket ? t("Connected") : status.retrying ? t("Retrying") : status.initialized ? t("Reconnecting") : t("Not connected")),
        fact(t("On the LAN"), tn("{n} device", "{n} devices", status.lanDevices ?? 0)),
        fact(t("In HomeKit"), tn("{n} accessory", "{n} accessories", status.accessories ?? 0)));
    } catch { $("#status").replaceChildren(); }
  }

  // MARK: Settings

  function prefillSettings() {
    $("#mode").value = config.mode || "auto";
    $("#debug").checked = !!config.debug;
    $("#offline-as-off").checked = !!config.offlineAsOff;
  }

  function prefillLogin() {
    if (config.username) $("#username").value = config.username;
    if (config.password) $("#password").value = config.password;
    if (config.countryCode) $("#countryCode").value = config.countryCode;
  }

  async function saveConfiguration(button) {
    await act(button, async () => {
      clearProblem($("#save-problem"));
      try {
        let block;
        const result = await homeswift.updateBlock((current) => {
          block = { ...current, ...(pendingAccount || {}), platform: "eWeLink", name: current.name || name || "eWeLink", mode: $("#mode").value };
          if ($("#debug").checked) block.debug = true; else delete block.debug;
          if ($("#offline-as-off").checked) block.offlineAsOff = true; else delete block.offlineAsOff;
          return block;
        });
        config = block;
        pendingAccount = null;
        const pending = result.restartNeeded || [];
        $("#restart").classList.toggle("hidden", pending.length === 0);
        $("#complete-text").replaceChildren(el("strong", { text: t("All done!") }), " ", pending.length
          ? t("The configuration is saved. Restart Homeswift to apply the rest ({changes}).", { changes: pending.map((change) => HomeswiftI18n.message(change)).join("; ") })
          : t("The configuration is saved and the plugin reloaded with it."));
        $("#restart-status").textContent = "";
        showStep("complete");
      } catch (e) {
        showProblem($("#save-problem"), e.message || t("Failed to save configuration"), "Saving this instance's block of config.json from the eWeLink plugin settings failed.");
      }
    });
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    $("#restart-status").textContent = t("Restarting…");
    let back = false;
    for (let tries = 0; tries < 60 && !back; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("status"); back = true; } catch { /* not back yet */ }
    }
    $("#restart-status").textContent = back ? t("Homeswift restarted.") : t("Homeswift has not answered for a minute: check its log, then reload this page.");
    $("#restart").classList.toggle("hidden", back);
  }

  // MARK: Events

  $("#login").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("#connect");
    if (button.disabled) return;
    const username = $("#username").value.trim();
    const password = $("#password").value;
    const countryCode = $("#countryCode").value;
    if (!username || !password) {
      showProblem($("#login-problem"), t("Please enter your username and password"), "The login form of the eWeLink plugin settings was submitted empty.");
      return;
    }
    await act(button, async () => {
      clearProblem($("#login-problem"));
      try {
        const answer = await request("login", { method: "POST", body: { username, password, countryCode } });
        region = answer.region;
        pendingAccount = { username, password, countryCode };
        showStep("devices");
        await loadDevices();
      } catch (e) {
        showProblem($("#login-problem"), e.message || t("Login failed"),
          `Logging in to the eWeLink cloud from the plugin settings failed. Selected country code: ${countryCode}.`);
      }
    });
  });

  $("#new-login").addEventListener("click", () => {
    $("#session").classList.add("hidden");
    showStep("login");
  });

  const tabs = [["#tab-devices", "#pane-devices"], ["#tab-settings", "#pane-settings"]];
  for (const [tab, pane] of tabs) {
    $(tab).addEventListener("click", () => {
      for (const [otherTab, otherPane] of tabs) {
        const selected = otherTab === tab;
        $(otherTab).classList.toggle("on", selected);
        $(otherTab).setAttribute("aria-selected", String(selected));
        $(otherPane).classList.toggle("hidden", !selected);
      }
    });
  }

  $("#refresh").addEventListener("click", loadDevices);
  $("#save").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#save-settings").addEventListener("click", (event) => saveConfiguration(event.currentTarget));
  $("#back").addEventListener("click", () => { showStep("devices"); loadDevices(); });
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, restart).catch((e) => HomeswiftCommon.showAlert(e.message)));

  // MARK: Config changes made elsewhere (the Expert editor, another tab, the Assistant), as the Homebridge page's
  // configChanged: the web UI sends no such event, so the block is read again whenever the page comes back into
  // view, and the settings are filled in again only when it changed. Unsaved choices stay otherwise.

  /// JSON with the keys sorted, so the same block written in another order compares equal.
  const canonical = (value) => JSON.stringify(value, (_, v) =>
    v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : v);

  async function followConfigChanges() {
    if (document.hidden) return;
    const before = canonical(config);
    let fresh;
    try { fresh = (await homeswift.readBlock()) || {}; } catch { return; }
    if (canonical(fresh) === before) return;
    config = fresh;
    prefillSettings();
  }
  document.addEventListener("visibilitychange", followConfigChanges);
  window.addEventListener("focus", followConfigChanges);

  // The country picker's regions in the page's language (the countries' own names have data-i18n).
  const regions = { Americas: t("Americas"), Europe: t("Europe"), "Asia Pacific": t("Asia Pacific"), "Middle East": t("Middle East"), Africa: t("Africa") };
  for (const group of document.querySelectorAll("#countryCode optgroup")) group.label = regions[group.label] ?? group.label;

  // MARK: Start: the block, then the plugin's session if it has one.

  (async () => {
    try { await readBlock(); } catch (e) { HomeswiftCommon.showAlert(e.message); }
    prefillLogin();
    prefillSettings();
    try {
      const session = await request("session");
      if (session.success) {
        region = session.region;
        $("#session").classList.remove("hidden");
        showStep("devices");
        await loadDevices();
        return;
      }
    } catch { /* no session: log in */ }
    showStep("login");
  })();
})();
