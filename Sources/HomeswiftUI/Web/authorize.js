"use strict";

// The OAuth sign-in page (/oauth/authorize): an MCP client such as claude.ai sends the user here. They sign in with
// their web UI account (the same login, two-factor code and throttle as the UI's), see which app asks and where
// approving sends them back, choose what it may do, and the bridge redirects to the app with a code or a refusal.
(() => {
  const { t } = HomeswiftI18n;
  const $ = (selector) => document.querySelector(selector);
  document.title = t("Connect to Homeswift");
  const query = Object.fromEntries(new URLSearchParams(location.search));

  async function api(path, { method = "GET", body } = {}) {
    const options = { method, credentials: "same-origin", headers: { "Accept-Language": HomeswiftI18n.locale } };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(path, options);
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw Object.assign(new Error(HomeswiftI18n.message((json && json.error) || `HTTP ${response.status}`)), { status: response.status });
    return json;
  }

  /// One of the page's states: the sign-in form, the choice, or a message alone.
  function show(part, lead) {
    $("#login").classList.toggle("hidden", part !== "login");
    $("#consent").classList.toggle("hidden", part !== "consent");
    if (lead !== undefined) $("#lead").textContent = lead;
  }
  const stop = (message) => { $("#title").textContent = t("Cannot connect"); show(null, message); };

  const scopes = {
    read: [t("Read"), t("See your accessories, rooms, scenes and the bridge's state. Changes nothing.")],
    control: [t("Control"), t("Also turn accessories on and off and run scenes. Locks, garage doors and alarms still ask you first.")],
    admin: [t("Administer"), t("Also change config.json, plugins and settings, and restart the bridge: everything this web UI can do.")],
  };

  async function start() {
    let state;
    try { state = await api("api/auth/state"); } catch (e) { stop(t("The bridge did not answer: {error}", { error: e.message })); return; }
    if (state.setupNeeded) { stop(t("This bridge has no account yet. Open its web UI and create the administrator first.")); return; }
    if (!state.authenticated) {
      show("login", t("Sign in with your Homeswift account to connect an app."));
      $("#login").username.focus();
      return;
    }
    let request;
    try { request = await api(`api/oauth/request?${new URLSearchParams(query)}`); } catch (e) { stop(e.message); return; }
    if (request.redirect) { location.replace(request.redirect); return; }
    $("#title").textContent = t("Connect {client}", { client: request.client });
    show("consent", state.mode === "form"
      ? t("{client} asks to use your bridge as {username}.", { client: request.client, username: request.username })
      : t("{client} asks to use your bridge. This web UI has no sign-in, so it acts as its administrator.", { client: request.client }));
    const fieldset = $("#scopes");
    fieldset.querySelectorAll(".scope").forEach((node) => node.remove());
    for (const name of request.choices) {
      const input = Object.assign(document.createElement("input"), { type: "radio", name: "scope", value: name, checked: name === request.suggested });
      const label = document.createElement("label");
      label.className = "scope";
      const title = document.createElement("strong");
      title.textContent = scopes[name][0];
      const help = document.createElement("span");
      help.className = "help";
      help.textContent = scopes[name][1];
      label.append(input, title, help);
      fieldset.append(label);
    }
    $("#read-only").classList.toggle("hidden", !request.readOnly);
    const destination = document.createElement("strong");
    destination.textContent = request.destination;
    // The sentence around the address, in the page's language: the address goes where {destination} stands.
    const [before, after = ""] = t("Allowing sends you back to {destination}. You can disconnect it from your account page at any time.").split("{destination}");
    $("#destination").replaceChildren(before, destination, after);
    $("#switch-user").classList.toggle("hidden", state.mode !== "form");
    // Nothing is focused and the answers wait a moment: the Enter that signed in, or a click meant for what was there
    // before, never approves an app the user has not seen.
    const buttons = [$("#allow"), $("#deny")];
    buttons.forEach((button) => { button.disabled = true; });
    setTimeout(() => buttons.forEach((button) => { button.disabled = false; }), 800);
  }

  // Signing in: the web UI's own login, so the session it makes also opens the UI.
  const login = $("#login");
  const askCode = (asked) => {
    $("#login-otp").classList.toggle("hidden", !asked);
    login.otp.required = asked;
    if (asked) login.otp.focus(); else login.otp.value = "";
  };
  for (const name of ["username", "password"]) login[name].addEventListener("input", () => askCode(false));
  login.addEventListener("submit", async (event) => {
    event.preventDefault();
    const submit = $("#login-submit");
    $("#login-error").textContent = "";
    submit.disabled = true;
    submit.textContent = t("Signing in…");
    const body = { username: login.username.value, password: login.password.value };
    if (!$("#login-otp").classList.contains("hidden")) body.otp = login.otp.value;
    try {
      await api("api/auth/login", { method: "POST", body });
      login.password.value = "";
      askCode(false);
      await start();
    } catch (e) {
      if (e.status === 412) askCode(true);
      else {
        $("#login-error").textContent = e.message;
        if (body.otp !== undefined) { login.otp.value = ""; login.otp.focus(); }
      }
    } finally {
      submit.disabled = false;
      submit.textContent = t("Sign in");
    }
  });

  // The answer: the bridge says where to send the browser, with a code or with access_denied.
  async function decide(approve) {
    const buttons = [$("#allow"), $("#deny")];
    buttons.forEach((button) => { button.disabled = true; });
    $("#consent-error").textContent = "";
    const chosen = $("#scopes input:checked");
    if (approve) $("#allow").textContent = t("Connecting…");
    try {
      const answer = await api("api/oauth/decision", { method: "POST", body: { ...query, approve, scope_granted: chosen ? chosen.value : null } });
      location.assign(answer.redirect);
    } catch (e) {
      $("#consent-error").textContent = e.message;
      buttons.forEach((button) => { button.disabled = false; });
      $("#allow").textContent = t("Allow");
    }
  }
  $("#consent").addEventListener("submit", (event) => { event.preventDefault(); decide(true); });
  $("#deny").addEventListener("click", () => decide(false));
  $("#switch-user").addEventListener("click", async () => {
    try { await api("api/auth/logout", { method: "POST" }); } catch {}
    $("#title").textContent = t("Connect to Homeswift");
    await start();
  });

  start();
})();
