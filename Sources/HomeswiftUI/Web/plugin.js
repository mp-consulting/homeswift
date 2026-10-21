// For a plugin's own pages, served at /plugins/<platform>/: homeswift.request() talks to the plugin instance
// named in the page's URL (?name=), with the session cookie. A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const platform = decodeURIComponent(location.pathname.split("/")[2] || "");
  const name = new URLSearchParams(location.search).get("name") || platform;
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  async function request(path, { method = "GET", body } = {}) {
    const options = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) { options.headers["Content-Type"] = "application/json"; options.body = JSON.stringify(body); }
    const response = await fetch(prefix + String(path).replace(/^\//, ""), options);
    if (response.status === 401) { location.href = "/"; throw new Error("signed out"); }
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = { error: text }; }
    if (!response.ok) throw new Error((json && json.error) || `HTTP ${response.status}`);
    return json;
  }

  window.homeswift = { platform, name, request, home: "/#plugins" };
})();
