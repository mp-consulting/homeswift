// A small TV remote for the web UI and plugin pages, after the Control Center remote: a round pad with OK in
// the middle, round keys (Back, Home, Info, Play/Pause, Mute) and a volume rocker. Each page says which
// actions its TV takes and how to send them: HomeKit's Remote Key on the Accessories page, the TV's own keys
// on a plugin's page. The pad also takes the keyboard (arrows, Enter, Backspace, Space) once focused.
(() => {
  "use strict";

  const icons = {
    up: '<path d="M6 15l6-6 6 6"/>', down: '<path d="M6 9l6 6 6-6"/>', left: '<path d="M15 6l-6 6 6 6"/>', right: '<path d="M9 6l6 6-6 6"/>',
    back: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5h.01"/>',
    playPause: '<path d="M4 6l7 6-7 6z"/><path d="M15 6v12M20 6v12"/>',
    mute: '<path d="M11 5 6 9H3v6h3l5 4z"/><path d="M22 9l-6 6M16 9l6 6"/>',
    volumeUp: '<path d="M12 5v14M5 12h14"/>', volumeDown: '<path d="M5 12h14"/>',
    power: '<path d="M12 3v9"/><path d="M6.3 7.2a8 8 0 1 0 11.4 0"/>',
  };
  const labels = {
    up: "Up", down: "Down", left: "Left", right: "Right", select: "OK", back: "Back", home: "Home", info: "Info",
    playPause: "Play/Pause", mute: "Mute", volumeUp: "Volume up", volumeDown: "Volume down", power: "Power",
  };
  const keyboard = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "select", Backspace: "back", " ": "playPause" };

  function svg(name) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    node.setAttribute("viewBox", "0 0 24 24");
    node.setAttribute("aria-hidden", "true");
    node.innerHTML = icons[name];
    return node;
  }

  /// `actions`: the actions this TV takes (others are left out). `send(action)`: a promise. `disabled`: the
  /// TV cannot take keys now. `extra`: nodes for the side (a power or Ambilight button).
  function build({ actions, send, disabled = false, label = "Remote", extra = [] }) {
    const has = new Set(actions);
    const remote = document.createElement("div");
    remote.className = `mini-remote${disabled ? " is-disabled" : ""}`;
    remote.setAttribute("role", "group");
    remote.setAttribute("aria-label", label);

    // Feedback on the press, at once; the key goes on release, as a remote's does, and a press dragged off
    // the key is cancelled.
    const key = (action, className, content) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = className;
      button.title = labels[action];
      button.setAttribute("aria-label", labels[action]);
      button.disabled = disabled || !has.has(action);
      button.append(content ?? svg(action));
      button.addEventListener("click", () => fire(action, button));
      return button;
    };
    const fire = async (action, button) => {
      if (!has.has(action) || disabled) return;
      button?.classList.add("sent");
      try { await send(action); } catch { remote.classList.add("failed"); setTimeout(() => remote.classList.remove("failed"), 600); }
      setTimeout(() => button?.classList.remove("sent"), 160);
    };

    const pad = document.createElement("div");
    pad.className = "pad";
    pad.tabIndex = disabled ? -1 : 0;
    pad.setAttribute("aria-label", `${label}: arrows move, Enter selects, Backspace goes back`);
    const ok = document.createElement("span");
    ok.textContent = "OK";
    pad.append(key("up", "pad-key up"), key("left", "pad-key left"), key("select", "pad-ok", ok), key("right", "pad-key right"), key("down", "pad-key down"));
    pad.addEventListener("keydown", (event) => {
      const action = keyboard[event.key];
      if (!action || !has.has(action)) return;
      event.preventDefault();
      const button = [...pad.querySelectorAll("button")].find((b) => b.classList.contains(action) || (action === "select" && b.classList.contains("pad-ok")));
      fire(action, button ?? null);
    });

    const keys = document.createElement("div");
    keys.className = "round-keys";
    for (const action of ["back", "home", "info", "playPause"]) if (has.has(action)) keys.append(key(action, "round-key"));

    const side = document.createElement("div");
    side.className = "remote-side";
    if (has.has("volumeUp") || has.has("volumeDown")) {
      const rocker = document.createElement("div");
      rocker.className = "rocker";
      rocker.setAttribute("role", "group");
      rocker.setAttribute("aria-label", "Volume");
      rocker.append(key("volumeUp", "rocker-key"), key("volumeDown", "rocker-key"));
      side.append(rocker);
    }
    if (has.has("mute")) side.append(key("mute", "round-key"));

    remote.append(pad, keys, side);
    if (extra.length) {
      const more = document.createElement("div");
      more.className = "remote-extra";
      more.append(...extra);
      remote.append(more);
    }
    return remote;
  }

  window.HomeswiftRemote = { build, icon: svg };
})();
