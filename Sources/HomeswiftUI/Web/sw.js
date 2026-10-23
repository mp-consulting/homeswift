// The web UI's service worker: it only shows the bridge's push notifications (Notifications page, "this browser")
// and opens the page one is about. It caches nothing and answers no request.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data ? event.data.text() : "" }; }
  event.waitUntil(self.registration.showNotification(data.title || "Homeswift", {
    body: data.body || "", tag: data.tag, icon: "/icon.svg", requireInteraction: !!data.urgent, data: { path: data.path || "/" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = (event.notification.data && event.notification.data.path) || "/";
  const target = new URL(path.startsWith("/") ? path : "/", self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
    for (const client of windows) {
      if (new URL(client.url).origin === self.location.origin && "focus" in client) {
        return client.focus().then((focused) => (focused && "navigate" in focused ? focused.navigate(target) : focused));
      }
    }
    return self.clients.openWindow(target);
  }));
});
