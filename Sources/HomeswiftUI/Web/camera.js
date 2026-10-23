// Camera views, for the Accessories page's camera cards and plugin pages: a 16:9 picture with the camera's name
// and state over it. While the view is on screen and the page visible, it plays the camera's live feed
// (/api/cameras/<id>/live, fMP4 through Media Source Extensions: ManagedMediaSource on iOS Safari 17 and later,
// MediaSource elsewhere), muted; otherwise, or when the camera has no live feed or the browser cannot play its
// codecs, a snapshot every few seconds (/api/cameras/<id>/snapshot). Off screen it fetches nothing, so a page
// of ten cameras does not pull ten streams. Loaded after common.js.
(() => {
  "use strict";

  const { el } = HomeswiftCommon;
  const MediaSourceType = window.ManagedMediaSource || window.MediaSource;
  const SNAPSHOT_EVERY = 3000;
  // Behind the live edge by more than this, the video jumps forward; buffer older than KEEP seconds goes.
  const MAX_LAG = 3, KEEP = 20;

  const glyphs = {
    muted: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m16 9 5 6M21 9l-5 6"/>',
    sound: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    fullscreen: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  };
  function glyph(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = glyphs[name];
    return svg;
  }
  const button = (name, label, onclick) => el("button", { type: "button", class: "camera-button", "aria-label": label, title: label, onclick }, glyph(name));

  /// "just now", "4 min ago", "2 h ago", or the date.
  function ago(date) {
    const seconds = (Date.now() - date) / 1000;
    if (seconds < 45) return "just now";
    if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
    if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
    return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  // Every view on the page, for the accessory events and the page's visibility.
  const views = new Set();
  const observer = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
    for (const entry of entries) entry.target.cameraView?.setVisible(entry.isIntersecting);
  }, { threshold: 0.2 }) : null;
  document.addEventListener("visibilitychange", () => { for (const view of views) view.update(); });
  // Views whose element left the page (another tab of the UI, a redrawn grid) stop and go.
  setInterval(() => { for (const view of views) if (!view.element.isConnected) view.destroy(); }, 5000);
  setInterval(() => { for (const view of views) view.tick(); }, 30000);

  /// A view of `camera` ({ id, name, doorbell, motion, recording, lastRing }): the element to place, and
  /// `motion(on)`, `ring(date)`, `recording(on)` to change what it shows.
  function view(camera) {
    const video = el("video", { muted: true, playsInline: true, autoplay: true, disablePictureInPicture: true, "aria-label": `Live video of ${camera.name}` });
    // ManagedMediaSource plays only with AirPlay off (or an AirPlay alternative), and a muted video autoplays.
    video.disableRemotePlayback = true;
    video.muted = true;
    video.setAttribute("muted", "");
    video.setAttribute("playsinline", "");
    const still = el("img", { class: "camera-still", alt: `Snapshot of ${camera.name}`, decoding: "async" });
    const liveBadge = el("span", { class: "camera-badge live hidden", text: "Live" });
    const stillBadge = el("span", { class: "camera-badge hidden" });
    const motionBadge = el("span", { class: "camera-badge motion hidden", text: "Motion" });
    const ringBadge = el("span", { class: "camera-badge ring hidden" });
    const recordingBadge = el("span", { class: "camera-badge recording hidden", text: "Recording", title: "HomeKit Secure Video records this camera's events" });
    const message = el("div", { class: "camera-message", text: "Connecting…" });
    const sound = button("muted", "Unmute", () => {
      video.muted = !video.muted;
      sound.replaceChildren(glyph(video.muted ? "muted" : "sound"));
      sound.setAttribute("aria-label", video.muted ? "Unmute" : "Mute");
      sound.title = sound.getAttribute("aria-label");
      if (!video.muted) video.play().catch(() => {});
    });
    sound.classList.add("hidden");
    const fullscreen = button("fullscreen", "Full screen", () => {
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      else if (element.requestFullscreen) element.requestFullscreen().catch(() => {});
      else if (element.webkitRequestFullscreen) element.webkitRequestFullscreen();
      // An iPhone has full screen for videos only.
      else if (video.webkitEnterFullscreen && state.live) video.webkitEnterFullscreen();
    });
    const refresh = button("refresh", "Refresh", () => { state.noLive = false; restart(); });
    const element = el("div", { class: "camera-view", "data-camera": camera.id },
      still, video, message,
      el("div", { class: "camera-top" },
        el("strong", { class: "camera-name", text: camera.name }),
        el("span", { class: "camera-badges" }, liveBadge, stillBadge, recordingBadge, motionBadge, ringBadge)),
      el("div", { class: "camera-controls" }, sound, refresh, fullscreen));

    const state = { visible: false, running: false, live: false, noLive: !MediaSourceType, abort: null, timer: null, lastRing: camera.lastRing ? new Date(camera.lastRing) : null, stalls: 0 };
    // A gap in the buffer (a fragment the server dropped for a slow reader): jump over it.
    video.addEventListener("waiting", () => {
      const ranges = video.buffered;
      for (let i = 0; i < ranges.length; i++) {
        if (ranges.start(i) > video.currentTime) { video.currentTime = ranges.start(i) + 0.05; break; }
      }
    });
    const url = (what, query = "") => `/api/cameras/${encodeURIComponent(camera.id)}/${what}${query}`;

    function show(what, text = "") {
      // "live" the video, "still" the snapshot, "message" a line over a dim picture.
      element.classList.toggle("is-live", what === "live");
      element.classList.toggle("has-still", !!still.src);
      message.textContent = text;
      message.classList.toggle("hidden", !text);
      liveBadge.classList.toggle("hidden", what !== "live");
      // The time a snapshot was taken, while one shows.
      stillBadge.classList.toggle("hidden", what !== "still");
    }

    // ---- Snapshots ----

    let stillURL = null;
    async function snapshot(signal) {
      const width = Math.min(1920, Math.max(320, Math.round(element.clientWidth * (window.devicePixelRatio || 1) / 160) * 160));
      const response = await fetch(url("snapshot", `?width=${width}&height=${Math.round(width * 9 / 16)}`), { credentials: "same-origin", cache: "no-store", signal });
      if (response.status === 401) { location.href = "/"; return; }
      if (!response.ok) {
        let text = `HTTP ${response.status}`;
        try { text = (await response.json()).error || text; } catch {}
        const error = new Error(text);
        error.status = response.status;
        throw error;
      }
      const blob = await response.blob();
      const next = URL.createObjectURL(blob);
      await new Promise((resolve) => { const image = new Image(); image.onload = image.onerror = resolve; image.src = next; });
      if (signal.aborted) { URL.revokeObjectURL(next); return; }
      still.src = next;
      if (stillURL) URL.revokeObjectURL(stillURL);
      stillURL = next;
      stillBadge.textContent = new Date().toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" });
    }

    async function snapshots(signal) {
      while (!signal.aborted) {
        try {
          await snapshot(signal);
          show("still");
          await sleep(SNAPSHOT_EVERY, signal);
        } catch (error) {
          if (signal.aborted) return;
          show("message", error.status === 409 ? "Turned off in the Home app" : error.status === 503 ? "Paused" : "No picture from the camera");
          // A camera that fails is asked less often.
          await sleep(SNAPSHOT_EVERY * 4, signal);
        }
      }
    }

    // ---- Live ----

    async function live(signal) {
      const response = await fetch(url("live"), { credentials: "same-origin", cache: "no-store", signal });
      if (response.status === 401) { location.href = "/"; return false; }
      if (!response.ok) {
        // No feed from this camera: snapshots, until Refresh. Busy or failing: snapshots, live again later.
        if (response.status === 404) state.noLive = true;
        if (response.status === 409) { show("message", "Turned off in the Home app"); state.noLive = true; }
        if (response.status === 503) { show("message", "Paused"); state.noLive = true; }
        response.body?.cancel().catch(() => {});
        return false;
      }
      const type = response.headers.get("X-Camera-Mime-Type") || "video/mp4";
      if (!MediaSourceType.isTypeSupported(type)) {
        state.noLive = true;
        response.body.cancel().catch(() => {});
        show("message", still.src ? "" : "This browser cannot play this camera's video");
        return false;
      }
      sound.classList.toggle("hidden", !/mp4a|opus|ac-3|ec-3/i.test(type));
      const source = new MediaSourceType();
      const sourceURL = URL.createObjectURL(source);
      video.src = sourceURL;
      signal.addEventListener("abort", () => { video.removeAttribute("src"); video.load(); URL.revokeObjectURL(sourceURL); });
      await new Promise((resolve) => source.addEventListener("sourceopen", resolve, { once: true }));
      if (signal.aborted) return true;
      const buffer = source.addSourceBuffer(type);
      const queue = [];
      let lastTrim = 0;
      const pump = () => {
        if (buffer.updating || signal.aborted || source.readyState !== "open") return;
        const ranges = buffer.buffered;
        if (ranges.length) {
          const end = ranges.end(ranges.length - 1);
          // The live edge, not the past: a tab in the background or a slow network falls behind.
          if (end - video.currentTime > MAX_LAG) video.currentTime = Math.max(ranges.start(ranges.length - 1), end - 0.5);
          const start = ranges.start(0);
          if (video.currentTime - start > KEEP * 1.5 && Date.now() - lastTrim > 10000) {
            lastTrim = Date.now();
            buffer.remove(start, video.currentTime - KEEP);
            return;
          }
        }
        const chunk = queue.shift();
        if (!chunk) return;
        try {
          buffer.appendBuffer(chunk);
        } catch (error) {
          // Full: drop what was played and try again.
          if (error.name === "QuotaExceededError" && ranges.length) { queue.unshift(chunk); buffer.remove(ranges.start(0), Math.max(ranges.start(0) + 0.1, video.currentTime - 2)); }
          else throw error;
        }
      };
      buffer.addEventListener("updateend", pump);
      video.addEventListener("playing", () => { state.live = true; show("live"); }, { once: true });
      const reader = response.body.getReader();
      signal.addEventListener("abort", () => reader.cancel().catch(() => {}));
      let started = false;
      // Stalled: no new frame for a while, start again.
      let lastTime = -1, stalledSince = Date.now();
      const watchdog = setInterval(() => {
        if (video.currentTime !== lastTime) { lastTime = video.currentTime; stalledSince = Date.now(); return; }
        if (Date.now() - stalledSince > 10000) reader.cancel().catch(() => {});
      }, 2000);
      signal.addEventListener("abort", () => clearInterval(watchdog));
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done || signal.aborted) break;
          queue.push(value);
          pump();
          if (!started) { started = true; video.play().catch(() => {}); }
        }
      } finally {
        clearInterval(watchdog);
      }
      return true;
    }

    // ---- Running ----

    const sleep = (ms, signal) => new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
    });

    async function run(signal) {
      // A first picture at once while the live feed connects, then live; snapshots when there is none.
      const first = snapshot(signal).then(() => { if (!state.live) show("still"); }).catch(() => {});
      while (!signal.aborted) {
        if (state.noLive) { await first; await snapshots(signal); return; }
        let played = false;
        try {
          played = await live(signal);
        } catch {
          played = false;
        }
        if (signal.aborted) return;
        const wasLive = state.live;
        state.live = false;
        video.removeAttribute("src");
        video.load();
        if (wasLive) { show(still.src ? "still" : "message", still.src ? "" : "Reconnecting…"); await sleep(1500, signal); continue; }
        if (state.noLive) continue;
        // Live failed: snapshots for a while, then live again.
        const pause = new AbortController();
        const done = () => pause.abort();
        signal.addEventListener("abort", done, { once: true });
        setTimeout(done, played ? 2000 : 30000);
        await first;
        await snapshots(pause.signal);
      }
    }

    function start() {
      if (state.running) return;
      state.running = true;
      state.abort = new AbortController();
      show(still.src ? "still" : "message", still.src ? "" : "Connecting…");
      run(state.abort.signal);
    }
    function stop() {
      if (!state.running) return;
      state.running = false;
      state.live = false;
      state.abort.abort();
      state.abort = null;
      liveBadge.classList.add("hidden");
      element.classList.remove("is-live");
    }
    function restart() { stop(); update(); }
    function update() {
      if (state.visible && document.visibilityState === "visible" && element.isConnected) start(); else stop();
    }

    const controller = {
      element, camera,
      setVisible(visible) { state.visible = visible; update(); },
      update,
      tick() { if (state.lastRing) ringBadge.textContent = `Rang ${ago(state.lastRing)}`; },
      motion(on) { motionBadge.classList.toggle("hidden", !on); element.classList.toggle("motion", !!on); },
      recording(on) { recordingBadge.classList.toggle("hidden", !on); },
      ring(date = new Date()) {
        state.lastRing = date;
        ringBadge.classList.remove("hidden");
        controller.tick();
        // A ring that just happened stands out for a moment.
        if (Date.now() - date < 60000) { ringBadge.classList.remove("fresh"); void ringBadge.offsetWidth; ringBadge.classList.add("fresh"); }
      },
      destroy() { stop(); observer?.unobserve(element); views.delete(controller); if (stillURL) URL.revokeObjectURL(stillURL); },
    };
    element.cameraView = controller;
    views.add(controller);
    controller.motion(camera.motion);
    controller.recording(camera.recording);
    if (state.lastRing) controller.ring(state.lastRing);
    if (observer) observer.observe(element); else controller.setVisible(true);
    return controller;
  }

  /// An accessory event from the page's event stream: motion and rings for the views of that accessory.
  function event({ id, service, characteristic, value }) {
    for (const view of views) {
      if (view.camera.id !== id) continue;
      if (characteristic === "Motion Detected") view.motion(value === true || value === 1);
      else if (characteristic === "Active" && service === "CameraRecordingManagement") view.recording(value === 1);
      else if (characteristic === "Programmable Switch Event" && view.camera.doorbell && value !== null) view.ring(new Date());
    }
  }

  window.HomeswiftCamera = { view, event, supported: !!MediaSourceType };
})();
