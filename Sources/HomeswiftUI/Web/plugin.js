// For a plugin's own pages, served at /plugins/<platform>/: homeswift.request() talks to the plugin instance
// named in the page's URL (?name=), with the session cookie; homeswift.el() and homeswift.$() build and find
// elements the way the UI's own pages do. A signed-out visitor is sent to the login page.
(() => {
  "use strict";
  const platform = decodeURIComponent(location.pathname.split("/")[2] || "");
  const name = new URLSearchParams(location.search).get("name") || platform;
  const prefix = `/api/plugins/${encodeURIComponent(platform)}/${encodeURIComponent(name)}/`;

  const $ = (selector, root = document) => root.querySelector(selector);
  const el = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (key.startsWith("data-")) node.setAttribute(key, value);
      else if (value !== undefined && value !== null && value !== false) node[key] = value;
    }
    for (const child of children.flat()) if (child != null) node.append(child.nodeType ? child : document.createTextNode(String(child)));
    return node;
  };

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

  window.homeswift = { platform, name, request, home: "/#plugins", $, el };
})();
