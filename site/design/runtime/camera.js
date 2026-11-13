// Camera views, for the Accessories page's camera cards and plugin pages: a 16:9 picture with the camera's name
// and state over it. While the view is on screen and the page visible, it plays the camera's live feed
// (/api/cameras/<id>/live, fMP4 through Media Source Extensions: ManagedMediaSource on iOS Safari 17 and later,
// MediaSource elsewhere), muted; otherwise, or when the camera has no live feed or the browser cannot play its
// codecs, a snapshot every few seconds (/api/cameras/<id>/snapshot). Off screen it fetches nothing, so a page
// of ten cameras does not pull ten streams. Loaded after common.js.
(() => {
  "use strict";

  const { el } = HomeswiftCommon;
  const { t, tn } = HomeswiftI18n;
  const MediaSourceType = window.ManagedMediaSource || window.MediaSource;
  const SNAPSHOT_EVERY = 3000;
  // Behind the live edge by more than this, the video jumps forward; buffer older than KEEP seconds goes.
  const MAX_LAG = 3, KEEP = 20;

  const glyphs = {
    muted: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="m16 9 5 6M21 9l-5 6"/>',
    sound: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    fullscreen: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
    refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
    move: '<path d="M12 3v18M3 12h18"/><path d="m9 6 3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  };
  function glyph(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = glyphs[name];
    return svg;
  }
  const button = (name, label, onclick) => el("button", { type: "button", class: "camera-button", "aria-label": label, title: label, onclick }, glyph(name));

  // ---- Pan and tilt ----

  // How often a held direction steps the camera again, once the last step was answered; how far the thumb leaves the
  // pad's centre before a direction counts; the pad's travel.
  const REPEAT_EVERY = 450, DEAD_ZONE = 0.28, TRAVEL = 0.42;
  // Each direction's arrow, from common.js's icons.
  const arrowIcons = { up: "up", down: "down", left: "back", right: "forward" };

  /// The pan and tilt of a camera that moves (/api/cameras/<id>/controls): a Move button for the view's controls, and
  /// the panel it opens over the picture: a pad to press or drag like a joystick, or to steer with the arrow keys once
  /// focused (the camera steps that way while it is held), then the presets and the home position. Each step waits for
  /// the camera's answer before the next: a battery camera answers late, and requests must not pile up.
  function panTilt(camera, url, setStatus, ask) {
    // The camera's controls once asked; false for a camera that does not move, which is not asked again.
    let controls = null, held = null, busy = false, timer = null;
    const thumb = el("span", { class: "ptz-thumb", "aria-hidden": "true" });
    const arrows = Object.fromEntries(Object.entries(arrowIcons).map(([direction, name]) => [direction,
      el("span", { class: `ptz-arrow ${direction}`, "aria-hidden": "true" }, HomeswiftCommon.icon(name))]));
    const pad = el("div", { class: "ptz-pad", role: "group", tabindex: "0", "aria-label": t("Pan and tilt {name}: press or drag, or use the arrow keys", { name: camera.name }) },
      thumb, ...Object.values(arrows));
    const presets = el("div", { class: "ptz-presets" });
    const panel = el("div", { class: "ptz-panel hidden" }, pad, presets);
    const toggle = button("move", t("Pan and tilt"), () => open(panel.classList.contains("hidden")));
    toggle.classList.add("hidden", "ptz-toggle");
    toggle.setAttribute("aria-expanded", "false");

    async function send(body) {
      busy = true;
      setStatus(t("Moving…"));
      try {
        await HomeswiftCommon.api(url("control"), { method: "POST", body });
        setStatus("");
        return true;
      } catch (error) {
        setStatus(error.message || t("The camera did not move"), true);
        return false;
      } finally {
        busy = false;
      }
    }
    // A held direction: a step now, the next once it was answered and REPEAT_EVERY went by, until let go.
    async function hold(direction) {
      if (held === direction) return;
      held = direction;
      clearTimeout(timer);
      while (held === direction) {
        if (!busy && !(await send({ move: direction }))) { held = null; break; }
        await new Promise((resolve) => { timer = setTimeout(resolve, REPEAT_EVERY); });
      }
    }
    function release() { held = null; clearTimeout(timer); }

    // The thumb follows the pointer from where it was pressed, held inside the pad with growing resistance past its
    // travel, and springs back to the centre when let go.
    let origin = null;
    function place(dx, dy) {
      const radius = pad.clientWidth * TRAVEL, distance = Math.hypot(dx, dy);
      const reach = distance > radius ? radius + (distance - radius) * radius / (radius + (distance - radius) * 1.8) : distance;
      const scale = distance ? reach / distance : 0;
      thumb.style.transform = `translate(${dx * scale}px, ${dy * scale}px)`;
      if (distance / pad.clientWidth < DEAD_ZONE) { mark(null); release(); return; }
      const direction = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up");
      if (!controls?.directions.includes(direction)) { mark(null); release(); return; }
      mark(direction);
      hold(direction);
    }
    function mark(direction) {
      for (const [name, arrow] of Object.entries(arrows)) arrow.classList.toggle("active", name === direction);
    }
    pad.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      pad.setPointerCapture(event.pointerId);
      pad.classList.add("dragging");
      const box = pad.getBoundingClientRect();
      origin = { x: box.left + box.width / 2, y: box.top + box.height / 2 };
      // A press on an arrow is that direction at once; anywhere else, where the pointer is from the centre.
      place(event.clientX - origin.x, event.clientY - origin.y);
    });
    pad.addEventListener("pointermove", (event) => { if (origin) place(event.clientX - origin.x, event.clientY - origin.y); });
    const letGo = () => {
      if (!origin) return;
      origin = null;
      pad.classList.remove("dragging");
      thumb.style.transform = "";
      mark(null);
      release();
    };
    pad.addEventListener("pointerup", letGo);
    pad.addEventListener("pointercancel", letGo);
    pad.addEventListener("lostpointercapture", letGo);
    const keys = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
    pad.addEventListener("keydown", (event) => {
      const direction = keys[event.key];
      if (!direction) { if (event.key === "Escape") { open(false); toggle.focus(); } return; }
      event.preventDefault();
      if (event.repeat) return;
      mark(direction);
      hold(direction);
    });
    pad.addEventListener("keyup", (event) => { if (keys[event.key]) { mark(null); release(); } });
    pad.addEventListener("blur", () => { mark(null); release(); });

    function open(on) {
      panel.classList.toggle("hidden", !on);
      toggle.setAttribute("aria-expanded", String(on));
      toggle.classList.toggle("active", on);
      if (!on) { release(); mark(null); }
    }
    function draw() {
      for (const [direction, arrow] of Object.entries(arrows)) arrow.classList.toggle("off", !controls.directions.includes(direction));
      const chips = [];
      if (controls.home) chips.push(el("button", { type: "button", class: "ptz-chip", onclick: () => send({ home: true }) }, HomeswiftCommon.icon("house"), el("span", { text: t("Home position") })));
      for (const preset of controls.presets) {
        chips.push(el("button", { type: "button", class: "ptz-chip", onclick: () => send({ preset: preset.id }) }, HomeswiftCommon.icon("location"), el("span", { text: preset.name })));
      }
      presets.replaceChildren(...chips);
      presets.classList.toggle("hidden", !chips.length);
    }

    return {
      toggle, panel,
      /// Asks what the camera can do once its picture is live; a camera that does not move keeps no button.
      async live(on) {
        if (!on) { open(false); return; }
        if (controls === false) return;
        if (controls) { toggle.classList.remove("hidden"); return; }
        const answer = await ask();
        if (answer === undefined || controls) return;
        if (!answer?.directions?.length && !answer?.presets?.length && !answer?.home) { controls = false; return; }
        controls = { directions: answer.directions ?? [], presets: answer.presets ?? [], home: !!answer.home };
        draw();
        toggle.classList.remove("hidden");
      },
      hide() { toggle.classList.add("hidden"); open(false); },
    };
  }

  // ---- Talk ----

  // Milliseconds of audio per message: short over the WebSocket, longer per request. Audio waits at most TALK_BACKLOG
  // milliseconds to go, the rest dropped, so speech stays live. The WebSocket has SOCKET_WAIT to open before requests
  // take over.
  const SOCKET_CHUNK = 40, REQUEST_CHUNK = 100, TALK_BACKLOG = 1000, SOCKET_WAIT = 3000;

  /// The microphone of a camera with a speaker (`talk` in /api/cameras/<id>/controls): a button that starts and stops
  /// a Talk. The microphone is resampled to the camera's rate by talk-worklet.js and sent over a WebSocket
  /// (/api/cameras/<id>/talk), or, when none opens (a proxy that does not pass them), in short requests one after the
  /// other. `hooks.started()` and `hooks.stopped()` let the view quiet the camera's own sound meanwhile.
  function talker(camera, url, setStatus, ask, hooks) {
    // The rate the camera takes once asked; false for a camera without a speaker, which is not asked again.
    let format = null, session = null;
    const toggle = button("mic", t("Talk"), () => (session ? stop() : start()));
    toggle.classList.add("hidden", "talk-toggle");
    toggle.setAttribute("aria-pressed", "false");

    function mark(on) {
      const label = on ? t("Stop talking") : t("Talk");
      toggle.classList.toggle("talking", on);
      toggle.setAttribute("aria-pressed", String(on));
      toggle.setAttribute("aria-label", label);
      toggle.title = label;
    }
    const randomID = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const bridgeMessage = (text) => window.HomeswiftI18n?.message(text) ?? text;

    async function start() {
      if (!navigator.mediaDevices?.getUserMedia || !window.AudioWorkletNode) {
        // Browsers give the microphone to secure pages only: HTTPS, or localhost.
        setStatus(window.isSecureContext ? t("This browser cannot use the microphone") : t("The microphone needs the web UI over HTTPS"), true);
        return;
      }
      const current = { id: randomID(), seq: 0, queue: [], sending: false, ended: false, socket: null };
      session = current;
      mark(true);
      hooks.started();
      setStatus(t("Starting the microphone…"));
      try {
        // Made during the click, so Safari lets it run.
        current.context = new AudioContext();
        current.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 } });
        if (current.ended) return;
        // The Talk starts once the microphone is granted: the bridge ends one that stays silent.
        current.socket = await openSocket(current);
        if (current.ended) { current.socket?.close(1000); return; }
        if (!current.socket) await HomeswiftCommon.api(url("talk"), { method: "POST", body: { talk: current.id, sampleRate: format.sampleRate } });
        if (current.ended) return;
        await current.context.audioWorklet.addModule("/talk-worklet.js");
        await current.context.resume();
        if (current.ended) return;
        const source = current.context.createMediaStreamSource(current.stream);
        const chunk = current.socket ? SOCKET_CHUNK : REQUEST_CHUNK;
        current.node = new AudioWorkletNode(current.context, "homeswift-talk", { processorOptions: { rate: format.sampleRate, chunk } });
        current.node.port.onmessage = (event) => (current.socket ? sendSocket(current, event.data) : enqueue(current, event.data));
        // The worklet runs only while it leads to the speakers: through a silent gain, so nothing is heard here.
        const silent = current.context.createGain();
        silent.gain.value = 0;
        source.connect(current.node).connect(silent).connect(current.context.destination);
        setStatus(t("Talking on {name}", { name: camera.name }));
      } catch (error) {
        if (current.ended) return;
        const blocked = error?.name === "NotAllowedError" || error?.name === "SecurityError";
        fail(current, blocked ? t("The microphone is blocked for this page") : error?.name === "NotFoundError" ? t("No microphone found") : error.message || t("The camera could not take the microphone"));
      }
    }

    /// The Talk's WebSocket once the bridge said the Talk started; null when none opened, for the requests to try (they
    /// say why the bridge refuses, which a refused upgrade cannot); throws the bridge's refusal of the Talk itself.
    function openSocket(current) {
      if (!window.WebSocket) return Promise.resolve(null);
      return new Promise((resolve, reject) => {
        let socket = null, settled = false, timer = null;
        const settle = (value, error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (error) reject(error); else resolve(value);
        };
        try {
          socket = new WebSocket(`${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}${url(`talk?sampleRate=${format.sampleRate}`)}`);
        } catch {
          resolve(null);
          return;
        }
        socket.binaryType = "arraybuffer";
        timer = setTimeout(() => { socket.close(); settle(null); }, SOCKET_WAIT);
        socket.onmessage = (event) => {
          let message = null;
          try { message = JSON.parse(event.data); } catch {}
          if (!settled) {
            if (message?.talk) settle(socket);
            else settle(null, new Error(bridgeMessage(message?.error) || t("The camera could not take the microphone")));
          } else if (message?.error && !current.ended) {
            // The camera gave up.
            fail(current, bridgeMessage(message.error));
          }
        };
        socket.onclose = () => {
          if (!settled) settle(null);
          else if (!current.ended) fail(current, t("The camera stopped taking the microphone"));
        };
      });
    }
    function sendSocket(current, buffer) {
      if (current.ended || current.socket.readyState !== WebSocket.OPEN) return;
      // A slow link: audio that would wait longer than TALK_BACKLOG is dropped rather than piling up.
      if (current.socket.bufferedAmount > format.sampleRate * 2 * TALK_BACKLOG / 1000) return;
      current.socket.send(buffer);
    }

    function enqueue(current, buffer) {
      if (current.ended) return;
      const bytes = new Uint8Array(buffer);
      let text = "";
      for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      current.queue.push({ seq: current.seq++, pcm: btoa(text) });
      if (current.queue.length > TALK_BACKLOG / REQUEST_CHUNK) current.queue.shift();
      pump(current);
    }
    // One request at a time, in order; the end goes after the audio before it.
    async function pump(current) {
      if (current.sending) return;
      current.sending = true;
      try {
        while (current.queue.length) {
          const body = current.queue.shift();
          await HomeswiftCommon.api(url(`talk/${current.id}`), { method: "POST", body });
        }
      } catch (error) {
        // The Talk is over on the bridge's side: the camera gave up (502), or it ended (410).
        if (!current.ended) fail(current, error.message || t("The camera stopped taking the microphone"));
      } finally {
        current.sending = false;
      }
    }

    function release(current) {
      current.ended = true;
      current.queue.length = 0;
      current.node?.port.close();
      current.stream?.getTracks().forEach((track) => track.stop());
      current.context?.close().catch(() => {});
      // Closing after what is buffered: the bridge ends the Talk with the socket.
      current.socket?.close(1000);
      if (session === current) {
        session = null;
        mark(false);
        hooks.stopped();
      }
    }
    function fail(current, text) {
      release(current);
      setStatus(text, true);
    }
    function stop() {
      const current = session;
      if (!current) return;
      const overRequests = !!current.node && !current.socket;
      release(current);
      setStatus("");
      // What is still on its way goes first; the bridge ends a Talk that falls silent anyway.
      if (overRequests) {
        const end = () => HomeswiftCommon.api(url(`talk/${current.id}`), { method: "POST", body: { end: true } }).catch(() => {});
        if (current.sending) setTimeout(end, REQUEST_CHUNK * 2); else end();
      }
    }

    return {
      toggle, stop,
      /// Asks whether the camera has a speaker once the view runs; one without keeps no button. A Talk goes on while the
      /// picture reconnects: only the view stopping (hide) ends it.
      async show() {
        if (format === false) return;
        if (format) { toggle.classList.remove("hidden"); return; }
        const answer = await ask();
        if (answer === undefined || format) return;
        if (!answer?.talk?.sampleRate) { format = false; return; }
        format = { sampleRate: answer.talk.sampleRate };
        toggle.classList.remove("hidden");
      },
      hide() { stop(); toggle.classList.add("hidden"); },
    };
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
    const video = el("video", { muted: true, playsInline: true, autoplay: true, disablePictureInPicture: true, "aria-label": t("Live video of {name}", { name: camera.name }) });
    // ManagedMediaSource plays only with AirPlay off (or an AirPlay alternative), and a muted video autoplays.
    video.disableRemotePlayback = true;
    video.muted = true;
    video.setAttribute("muted", "");
    video.setAttribute("playsinline", "");
    const still = el("img", { class: "camera-still", alt: t("Snapshot of {name}", { name: camera.name }), decoding: "async" });
    const liveBadge = el("span", { class: "camera-badge live hidden", text: t("Live") });
    const stillBadge = el("span", { class: "camera-badge hidden" });
    const motionBadge = el("span", { class: "camera-badge motion hidden", text: t("Motion") });
    const ringBadge = el("span", { class: "camera-badge ring hidden" });
    const recordingBadge = el("span", { class: "camera-badge recording hidden", text: t("Recording"), title: t("HomeKit Secure Video records this camera's events") });
    const message = el("div", { class: "camera-message", text: t("Connecting…") });
    // No picture from the camera: an old television's snow behind the message, drawn small and scaled up.
    const snow = el("canvas", { class: "camera-snow", width: 160, height: 90, "aria-hidden": "true" });
    function setMuted(muted) {
      video.muted = muted;
      sound.replaceChildren(glyph(muted ? "muted" : "sound"));
      sound.setAttribute("aria-label", muted ? t("Unmute") : t("Mute"));
      sound.title = sound.getAttribute("aria-label");
      if (!muted) video.play().catch(() => {});
    }
    // The camera's sound is muted while someone talks through it (`mutedForTalk`), so what its speaker plays does not
    // come back through its microphone and this one as an echo; it comes back with the Talk's end, unless the person
    // turned it on meanwhile (with headphones, say).
    let mutedForTalk = false;
    const sound = button("muted", t("Unmute"), () => {
      mutedForTalk = false;
      setMuted(!video.muted);
    });
    sound.classList.add("hidden");
    const fullscreen = button("fullscreen", t("Full screen"), () => {
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      else if (element.requestFullscreen) element.requestFullscreen().catch(() => {});
      else if (element.webkitRequestFullscreen) element.webkitRequestFullscreen();
      // An iPhone has full screen for videos only.
      else if (video.webkitEnterFullscreen && state.live) video.webkitEnterFullscreen();
    });
    const refresh = button("refresh", t("Refresh"), () => { state.noLive = false; restart(); });
    const url = (what, query = "") => `/api/cameras/${encodeURIComponent(camera.id)}/${what}${query}`;
    // What the camera is doing after a pan or tilt or with the microphone: under way, or why it did not.
    const ptzStatus = el("span", { class: "ptz-status hidden", role: "status", "aria-live": "polite" });
    const setStatus = (text, failed = false) => {
      ptzStatus.textContent = text;
      ptzStatus.classList.toggle("hidden", !text);
      ptzStatus.classList.toggle("failed", failed);
      clearTimeout(ptzStatus.timer);
      if (failed) ptzStatus.timer = setTimeout(() => ptzStatus.classList.add("hidden"), 4000);
    };
    // What the live view's buttons can do (/api/cameras/<id>/controls), asked once for both: the answer, false for a
    // camera that neither moves nor talks or a read-only user, undefined when it could not be asked (asked again later).
    let controlsAnswer = null, controlsAsking = null;
    const askControls = () => {
      if (controlsAnswer !== null) return Promise.resolve(controlsAnswer);
      controlsAsking ??= HomeswiftCommon.api(url("controls"))
        .then((answer) => (controlsAnswer = answer ?? false))
        .catch((error) => {
          if (error.status === 404 || error.status === 403) controlsAnswer = false;
          return controlsAnswer === false ? false : undefined;
        })
        .finally(() => { controlsAsking = null; });
      return controlsAsking;
    };
    const ptz = panTilt(camera, url, setStatus, askControls);
    const talk = talker(camera, url, setStatus, askControls, {
      started() { if (!video.muted) { setMuted(true); mutedForTalk = true; } },
      stopped() { if (mutedForTalk && video.muted) setMuted(false); mutedForTalk = false; },
    });
    const element = el("div", { class: "camera-view", "data-camera": camera.id },
      still, video, snow, message, ptz.panel,
      el("div", { class: "camera-top" },
        el("strong", { class: "camera-name", text: camera.name }),
        el("span", { class: "camera-badges" }, liveBadge, stillBadge, recordingBadge, motionBadge, ringBadge)),
      el("div", { class: "camera-controls" }, ptzStatus, talk.toggle, ptz.toggle, sound, refresh, fullscreen));

    const state = { visible: false, running: false, live: false, noLive: !MediaSourceType, abort: null, timer: null, lastRing: camera.lastRing ? new Date(camera.lastRing) : null, stalls: 0 };
    // A gap in the buffer (a fragment the server dropped for a slow reader): jump over it.
    video.addEventListener("waiting", () => {
      const ranges = video.buffered;
      for (let i = 0; i < ranges.length; i++) {
        if (ranges.start(i) > video.currentTime) { video.currentTime = ranges.start(i) + 0.05; break; }
      }
    });
    // The snow's frames, a few a second while the view runs; one frame under reduced motion.
    let snowFrame = 0, snowDrawn = 0;
    function drawSnow(now) {
      if (!element.classList.contains("no-signal") || !state.running) { snowFrame = 0; return; }
      if (now - snowDrawn > 60) {
        snowDrawn = now;
        const context = snow.getContext("2d"), image = context.createImageData(snow.width, snow.height);
        const pixels = new Uint32Array(image.data.buffer);
        for (let i = 0; i < pixels.length; i++) { const v = (Math.random() * 256) | 0; pixels[i] = 0xff000000 | (v << 16) | (v << 8) | v; }
        context.putImageData(image, 0, 0);
      }
      snowFrame = matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : requestAnimationFrame(drawSnow);
    }
    function snowing(on) {
      element.classList.toggle("no-signal", on);
      if (on && !snowFrame) snowFrame = requestAnimationFrame(drawSnow);
    }

    function show(what, text = "", { noSignal = false } = {}) {
      // "live" the video, "still" the snapshot, "message" a line over a dim picture (over snow when the camera sends none).
      snowing(what === "message" && noSignal && !still.src);
      element.classList.toggle("is-live", what === "live");
      ptz.live(what === "live");
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
      stillBadge.textContent = HomeswiftI18n.formatDate(new Date(), { hour: "numeric", minute: "2-digit", second: "2-digit" });
    }

    async function snapshots(signal) {
      while (!signal.aborted) {
        try {
          await snapshot(signal);
          show("still");
          await sleep(SNAPSHOT_EVERY, signal);
        } catch (error) {
          if (signal.aborted) return;
          const unavailable = error.status !== 409 && error.status !== 503;
          show("message", error.status === 409 ? t("Turned off in the Home app") : error.status === 503 ? t("Paused") : t("No picture from the camera"), { noSignal: unavailable });
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
        if (response.status === 409) { show("message", t("Turned off in the Home app")); state.noLive = true; }
        if (response.status === 503) { show("message", t("Paused")); state.noLive = true; }
        response.body?.cancel().catch(() => {});
        return false;
      }
      const type = response.headers.get("X-Camera-Mime-Type") || "video/mp4";
      if (!MediaSourceType.isTypeSupported(type)) {
        state.noLive = true;
        response.body.cancel().catch(() => {});
        show("message", still.src ? "" : t("This browser cannot play this camera's video"));
        return false;
      }
      sound.classList.toggle("hidden", !/mp4a|opus|ac-3|ec-3/i.test(type));
      const source = new MediaSourceType();
      const sourceURL = URL.createObjectURL(source);
      video.src = sourceURL;
      // This attempt's own clean-up, once, when the view stops or the attempt ends: a camera that reconnects for
      // hours does not pile up listeners on the run's signal, nor keep each attempt's MediaSource.
      const reader = response.body.getReader();
      let watchdog = null, detached = false;
      const detach = () => {
        if (detached) return;
        detached = true;
        clearInterval(watchdog);
        reader.cancel().catch(() => {});
        video.removeAttribute("src");
        video.load();
        URL.revokeObjectURL(sourceURL);
      };
      signal.addEventListener("abort", detach, { once: true });
      try {
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
        let started = false;
        // Stalled: no new frame for a while, start again.
        let lastTime = -1, stalledSince = Date.now();
        watchdog = setInterval(() => {
          if (video.currentTime !== lastTime) { lastTime = video.currentTime; stalledSince = Date.now(); return; }
          if (Date.now() - stalledSince > 10000) reader.cancel().catch(() => {});
        }, 2000);
        for (;;) {
          const { value, done } = await reader.read();
          if (done || signal.aborted) break;
          queue.push(value);
          pump();
          if (!started) { started = true; video.play().catch(() => {}); }
        }
        return true;
      } finally {
        signal.removeEventListener("abort", detach);
        detach();
      }
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
        if (wasLive) { show(still.src ? "still" : "message", still.src ? "" : t("Reconnecting…")); await sleep(1500, signal); continue; }
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
      show(still.src ? "still" : "message", still.src ? "" : t("Connecting…"));
      // Talking needs no picture: a camera that shows snapshots has its microphone too.
      talk.show();
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
      ptz.hide();
      talk.hide();
    }
    function restart() { stop(); update(); }
    function update() {
      if (state.visible && document.visibilityState === "visible" && element.isConnected) start(); else stop();
    }

    const controller = {
      element, camera,
      setVisible(visible) { state.visible = visible; update(); },
      update,
      tick() { if (state.lastRing) ringBadge.textContent = t("Rang {when}", { when: HomeswiftCommon.ago(state.lastRing) }); },
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
