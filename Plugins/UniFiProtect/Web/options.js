// The helpers of the Homebridge plugin's settings page that touch no element and that this page still uses (the ONVIF
// profiles of third-party-overrides.js, what may reach the Assistant, a device's problem), as window.ProtectOptions.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;

  /// Profiles with the same URLs are one stream: the one with the largest resolution stays.
  function dedupeProfilesByUrl(profiles) {
    const byKey = new Map();
    for (const profile of profiles) {
      const key = (profile.rtspUrl || "") + "|" + (profile.snapshotUrl || "");
      const existing = byKey.get(key);
      const pixels = (p) => (p?.resolution?.width ?? 0) * (p?.resolution?.height ?? 0);
      if (!existing || pixels(profile) > pixels(existing)) byKey.set(key, profile);
    }
    return [...byKey.values()];
  }

  function formatProfileLabel(profile, index) {
    const parts = [profile.name || t("Profile {n}", { n: index + 1 })];
    if (profile.resolution?.width && profile.resolution?.height) parts.push(profile.resolution.width + "×" + profile.resolution.height);
    if (profile.encoding) parts.push(profile.encoding);
    return parts.join(" — ");
  }

  // MARK: The Assistant: what may leave the page

  const ipv4 = /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b/g;
  const macPattern = /\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b/g;

  function scrubText(text, addresses = []) {
    let result = String(text ?? "");
    for (const address of addresses) {
      if (typeof address === "string" && address.trim()) result = result.split(address.trim()).join("[address]");
    }
    return result.replace(macPattern, "[MAC address]").replace(ipv4, "[IP address]");
  }

  window.ProtectOptions = { dedupeProfilesByUrl, formatProfileLabel, scrubText };
})();
