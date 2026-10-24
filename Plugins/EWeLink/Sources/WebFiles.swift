// THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
    public static let webFiles: [String: WebFile] = [
        "app.js": WebFile(contentType: "text/javascript; charset=utf-8", body: #"""
// The eWeLink page, after the Homebridge plugin's settings UI: connect the account (or reuse the plugin's
// session), the account's devices with their LAN and RF details (an mDNS scan runs while the cloud answers),
// the connection settings, and saving them into this instance's block, which reloads the plugin. The session
// stays in the plugin: the browser never sees a token.
(() => {
  "use strict";
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
    if (device.lanEnabled && device.lanIp) badges.push(el("span", { class: "pill lan", text: `LAN: ${device.lanIp}` }));
    else if (device.lanEnabled) badges.push(el("span", { class: "pill lan-warn", text: "LAN: No IP" }));
    else badges.push(el("span", { class: "pill", text: "Cloud" }));
    badges.push(el("span", { class: `pill status ${device.online ? "on" : "away"}`, text: device.online ? "Online" : "Offline" }));
    const problem = deviceProblem(device);
    return el("li", { class: `device ${device.isRfSubdevice ? "rf" : ""}` },
      el("div", { class: "info" },
        el("div", { class: "name", text: device.name }),
        el("div", { class: "meta" },
          el("span", { class: "mono", text: `ID: ${device.deviceId}` }),
          el("span", { text: `${device.brand || "Unknown"} — ${device.model || "Unknown"} (UIID: ${device.uiid ?? "N/A"})` })),
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
      : [el("li", { class: "empty" }, el("p", { text: "No devices found" }), el("p", { class: "muted", text: "Connect your eWeLink account and click Refresh." }))]));
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
        showProblem($("#devices-problem"), e.message || "Failed to load devices",
          "Loading the device list from the eWeLink cloud (plus a 3 second mDNS LAN scan) failed in the plugin settings.");
      }
    });
    await loadStatus();
  }

  async function loadStatus() {
    try {
      const status = await request("status");
      $("#status").replaceChildren(
        fact("Cloud", status.websocket ? "Connected" : status.retrying ? "Retrying" : status.initialized ? "Reconnecting" : "Not connected"),
        fact("On the LAN", `${status.lanDevices ?? 0} device${status.lanDevices === 1 ? "" : "s"}`),
        fact("In HomeKit", `${status.accessories ?? 0} accessor${status.accessories === 1 ? "y" : "ies"}`));
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
        $("#complete-text").replaceChildren(el("strong", { text: "All done!" }), pending.length
          ? ` The configuration is saved. Restart Homeswift to apply the rest (${pending.join("; ")}).`
          : " The configuration is saved and the plugin reloaded with it.");
        $("#restart-status").textContent = "";
        showStep("complete");
      } catch (e) {
        alert(e.message || "Failed to save configuration");
      }
    });
  }

  async function restart() {
    await api("/api/restart", { method: "POST" });
    $("#restart-status").textContent = "Restarting…";
    for (let tries = 0; tries < 60; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      try { await request("status"); break; } catch { /* not back yet */ }
    }
    $("#restart-status").textContent = "Homeswift restarted.";
    $("#restart").classList.add("hidden");
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
      showProblem($("#login-problem"), "Please enter your username and password", "The login form of the eWeLink plugin settings was submitted empty.");
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
        showProblem($("#login-problem"), e.message || "Login failed",
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
  $("#restart").addEventListener("click", (event) => act(event.currentTarget, restart).catch((e) => alert(e.message)));

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

  // MARK: Start: the block, then the plugin's session if it has one.

  (async () => {
    try { await readBlock(); } catch (e) { alert(e.message); }
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

"""#),
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>eWeLink</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
<style>
  /* The Homebridge plugin's settings page on the UI's materials: a numbered wizard (connect the account, the
     devices and settings, done) with one step showing at a time. */
  .page-head { align-items: center; }
  .tile.ewelink { background: linear-gradient(160deg, #ff7b6b, #e74c3c); }
  .step { margin-bottom: 22px; animation: materialize var(--normal) var(--ease-out); }
  .step-head { display: flex; align-items: center; gap: 12px; margin: 22px 0 12px; }
  .step-head h2 { margin: 0; }
  .step-number {
    width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; flex: none; font-weight: 600;
    background: linear-gradient(180deg, var(--accent-2), var(--accent)); color: var(--accent-text);
  }
  .step-number.done { background: linear-gradient(160deg, #6ee7a0, #23a55a); color: #fff; }
  .session { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .session p { margin: 2px 0 0; font-size: 0.8125rem; }
  .login { max-width: 520px; }
  .login .actions { margin-top: 16px; }
  .tabs { margin-bottom: 14px; }
  .list-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-bottom: 12px; border-bottom: 1px solid var(--line); }
  .list-head h3 { margin: 0; display: flex; align-items: center; gap: 8px; }
  .count { font-size: 0.75rem; font-weight: 600; padding: 1px 8px; border-radius: 999px; background: var(--material-thin); border: 1px solid var(--line); color: var(--muted); }
  .devices { list-style: none; margin: 0; padding: 0; }
  .device { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-start; gap: 6px 14px; padding: 12px 2px; border-bottom: 1px solid var(--line); }
  .device:last-child { border-bottom: 0; }
  .device .info { flex: 1 1 0; min-width: 0; }
  .device .name { font-weight: 500; }
  .device .meta { font-size: 0.8125rem; color: var(--muted); overflow-wrap: anywhere; }
  .device .meta .mono { margin-right: 8px; }
  .device .badges { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; flex: none; }
  .device .explain { flex: 0 0 100%; min-width: 0; }
  .device.rf { margin-left: 22px; padding-left: 12px; border-left: 3px solid #9c27b0; }
  .pill.lan { color: #1f6fe0; border-color: rgba(31, 111, 224, 0.35); }
  .pill.lan-warn { color: var(--warn); border-color: rgba(201, 115, 26, 0.35); }
  .pill.rf { color: #9c27b0; border-color: rgba(156, 39, 176, 0.35); }
  .buttons { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
  .buttons span { font-size: 0.75rem; font-weight: 500; padding: 1px 8px; border-radius: 6px; color: #9c27b0; background: rgba(156, 39, 176, 0.1); }
  .problem { margin-bottom: 12px; padding: 12px 14px; border-radius: 14px; border: 1px solid rgba(208, 56, 59, 0.35); background: rgba(208, 56, 59, 0.06); }
  .problem p { margin: 0; color: var(--error); }
  .problem .explain { margin-top: 6px; }
  .empty { text-align: center; padding: 26px 12px; }
  .empty p { margin: 4px 0; }
  .status-facts { margin-bottom: 14px; }
  .busy::after {
    content: ""; display: inline-block; width: 0.9em; height: 0.9em; margin-left: 8px; vertical-align: -0.12em;
    border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) {
    .step { animation: none; }
    .busy::after { animation: none; border-right-color: currentColor; opacity: 0.5; }
  }
</style>
</head>
<body>
<header><a class="brand" href="/" aria-label="Homeswift" title="Homeswift"><img src="/icon.svg" class="logo" alt=""></a></header>
<main>
  <div class="page-head">
    <span class="tile large ewelink" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M9 2v6M15 2v6"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v5"/></svg></span>
    <div class="who">
      <h1>eWeLink</h1>
      <p class="muted">Connect your eWeLink account to manage devices in HomeKit.</p>
    </div>
  </div>

  <section id="step-login" class="step hidden">
    <div class="step-head"><span class="step-number">1</span><h2>Connect your eWeLink account</h2></div>
    <form id="login" class="card login" novalidate>
      <label class="field"><span class="field-title">Email or phone number</span>
        <input id="username" type="text" placeholder="your@email.com" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false">
        <span class="help">Your eWeLink account's email or phone number.</span></label>
      <label class="field"><span class="field-title">Password</span>
        <input id="password" type="password" placeholder="••••••••" autocomplete="current-password" enterkeyhint="go"></label>
      <label class="field"><span class="field-title">Country code</span>
        <select id="countryCode">
          <optgroup label="Americas">
            <option value="+54">Argentina (+54)</option><option value="+55">Brazil (+55)</option><option value="+56">Chile (+56)</option>
            <option value="+57">Colombia (+57)</option><option value="+52">Mexico (+52)</option><option value="+51">Peru (+51)</option>
            <option value="+1">United States / Canada (+1)</option><option value="+58">Venezuela (+58)</option>
          </optgroup>
          <optgroup label="Europe">
            <option value="+43">Austria (+43)</option><option value="+32">Belgium (+32)</option><option value="+359">Bulgaria (+359)</option>
            <option value="+420">Czech Republic (+420)</option><option value="+45">Denmark (+45)</option><option value="+358">Finland (+358)</option>
            <option value="+33">France (+33)</option><option value="+49">Germany (+49)</option><option value="+30">Greece (+30)</option>
            <option value="+36">Hungary (+36)</option><option value="+353">Ireland (+353)</option><option value="+39">Italy (+39)</option>
            <option value="+31">Netherlands (+31)</option><option value="+47">Norway (+47)</option><option value="+48">Poland (+48)</option>
            <option value="+351">Portugal (+351)</option><option value="+40">Romania (+40)</option><option value="+7">Russia (+7)</option>
            <option value="+421">Slovakia (+421)</option><option value="+34">Spain (+34)</option><option value="+46">Sweden (+46)</option>
            <option value="+41">Switzerland (+41)</option><option value="+90">Turkey (+90)</option><option value="+380">Ukraine (+380)</option>
            <option value="+44">United Kingdom (+44)</option>
          </optgroup>
          <optgroup label="Asia Pacific">
            <option value="+61">Australia (+61)</option><option value="+86">China (+86)</option><option value="+852">Hong Kong (+852)</option>
            <option value="+91">India (+91)</option><option value="+62">Indonesia (+62)</option><option value="+81">Japan (+81)</option>
            <option value="+853">Macau (+853)</option><option value="+60">Malaysia (+60)</option><option value="+64">New Zealand (+64)</option>
            <option value="+63">Philippines (+63)</option><option value="+65">Singapore (+65)</option><option value="+82">South Korea (+82)</option>
            <option value="+886">Taiwan (+886)</option><option value="+66">Thailand (+66)</option><option value="+84">Vietnam (+84)</option>
          </optgroup>
          <optgroup label="Middle East">
            <option value="+972">Israel (+972)</option><option value="+965">Kuwait (+965)</option><option value="+974">Qatar (+974)</option>
            <option value="+966">Saudi Arabia (+966)</option><option value="+971">UAE (+971)</option>
          </optgroup>
          <optgroup label="Africa">
            <option value="+20">Egypt (+20)</option><option value="+212">Morocco (+212)</option><option value="+234">Nigeria (+234)</option>
            <option value="+27">South Africa (+27)</option>
          </optgroup>
        </select></label>
      <div class="actions"><button id="connect" class="primary" type="submit">Connect account</button></div>
    </form>
    <div id="login-problem" class="problem hidden"></div>
  </section>

  <section id="step-devices" class="step hidden">
    <div class="step-head"><span class="step-number">2</span><h2>Your devices</h2></div>
    <div id="session" class="card session hidden">
      <div><strong>Active session detected</strong><p class="muted">Using the session the plugin logged in with.</p></div>
      <button id="new-login">Log in with another account</button>
    </div>
    <div class="group tabs" role="tablist">
      <button id="tab-devices" role="tab" class="on" aria-selected="true">Devices</button>
      <button id="tab-settings" role="tab" aria-selected="false">Settings</button>
    </div>
    <div id="pane-devices" class="card">
      <div id="status" class="facts status-facts"></div>
      <div class="list-head">
        <h3>Discovered devices <span id="device-count" class="count">0</span></h3>
        <button id="refresh">Refresh</button>
      </div>
      <div id="devices-problem" class="problem hidden"></div>
      <ul id="devices" class="devices"></ul>
      <div class="save-bar"><span class="muted">Saving writes the account and settings to this instance's block; the plugin reloads with them.</span>
        <button id="save" class="primary">Save configuration</button></div>
    </div>
    <div id="pane-settings" class="card hidden">
      <label class="field"><span class="field-title">Connection mode</span>
        <select id="mode"><option value="auto">Auto (LAN + Cloud)</option><option value="lan">LAN Only</option><option value="wan">Cloud Only</option></select>
        <span class="help">Auto mode tries LAN first, then falls back to cloud.</span></label>
      <label class="toggle"><span class="switch"><input id="debug" type="checkbox"><span></span></span>
        <span><span class="field-title">Enable debug logging</span><span class="help">Accessories log their debug lines (run homeswift with -D to see them).</span></span></label>
      <label class="toggle"><span class="switch"><input id="offline-as-off" type="checkbox"><span></span></span>
        <span><span class="field-title">Show offline devices as off</span><span class="help">Instead of "No Response" in the Home app.</span></span></label>
      <div class="save-bar"><span class="muted">The other options (per-device settings, simulations, RF sub-devices) are in Settings.</span>
        <button id="save-settings" class="primary">Save configuration</button></div>
    </div>
  </section>

  <section id="step-complete" class="step hidden">
    <div class="step-head"><span class="step-number done">✓</span><h2>Configuration complete</h2></div>
    <div class="card">
      <p id="complete-text"><strong>All done!</strong> The plugin reloaded with the new configuration.</p>
      <div class="actions">
        <button id="back">Back to the devices</button>
        <button id="restart" class="hidden">Restart Homeswift</button>
      </div>
      <p id="restart-status" class="status-line"></p>
    </div>
  </section>
</main>
<script src="/common.js"></script>
<script src="/plugin.js"></script>
<script src="app.js"></script>
</body>
</html>

"""#),
    ]
}
