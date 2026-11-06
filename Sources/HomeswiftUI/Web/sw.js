// The web UI's service worker: it only shows the bridge's push notifications (Notifications page, "this browser")
// and opens the page one is about. It caches nothing and answers no request. An Automation's buttons are the
// notification's actions where the browser shows them (Chromium): one acts with its single-use token, or opens its
// page; elsewhere (Safari, iOS) a tap opens the page listing them.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data ? event.data.text() : "" }; }
  const actions = Array.isArray(data.actions) ? data.actions : [];
  event.waitUntil(self.registration.showNotification(data.title || "Homeswift", {
    body: data.body || "", tag: data.tag, icon: "/icon.svg", requireInteraction: !!data.urgent || actions.length > 0, data: { path: data.path || "/", actions },
    actions: actions.slice(0, 3).map((action) => ({ action: action.action, title: action.title })),
  }));
});

/// A path on this origin only: "//host" and "/\host" would leave it.
const local = (path) => new URL(/^\/(?![/\\])/.test(path || "") ? path : "/", self.location.origin).href;

function open(path) {
  const target = local(path);
  return self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
    for (const client of windows) {
      if (new URL(client.url).origin === self.location.origin && "focus" in client) {
        return client.focus().then((focused) => (focused && "navigate" in focused ? focused.navigate(target) : focused));
      }
    }
    return self.clients.openWindow(target);
  });
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const action = (data.actions || []).find((one) => one.action === event.action);
  if (action && action.act) {
    // Pressed in the notification: the button acts at once; if it cannot (used, expired), the page says why.
    event.waitUntil(fetch(local(action.act), { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", credentials: "omit" })
      .then((response) => (response.ok ? null : open(data.path))).catch(() => open(data.path)));
    return;
  }
  event.waitUntil(open(action && action.path ? action.path : data.path));
});
