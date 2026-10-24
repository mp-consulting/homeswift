// The logic of the Homebridge plugin's settings page that touches no element (option-state.js, the validity
// tests of renderer.js, the camera override bookkeeping of third-party-overrides.js, and the Assistant's
// whitelists), as window.ProtectOptions. Option entries keep the Homebridge format: Enable|Disable.<Option>
// [.<scope id>][.<value>], the controller's scope id being its address, as that page wrote it.
(() => {
  "use strict";
  const { t } = HomeswiftI18n;

  const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  /// Whether the categories of options apply to a device (all of them at the global and controller scopes).
  function validOptionCategory(device, category) {
    if (!device || device.modelKey === "nvr") return true;
    if (!category.modelKey?.some((model) => ["all", device.modelKey].includes(model))) return false;
    if (category.isNotProperty?.some((property) => device[property] === true)) return false;
    const key = "has" + device.modelKey.charAt(0).toUpperCase() + device.modelKey.slice(1) + "Feature";
    if (category[key]?.some((flag) => !device.featureFlags?.[flag])) return false;
    return true;
  }

  /// Whether an option applies to what the device can do.
  function validOption(device, option) {
    if (device && device.modelKey !== "nvr" && (
      (option.hasAccessFeature && (!device.accessDeviceMetadata?.featureFlags || !option.hasAccessFeature.some((flag) => device.accessDeviceMetadata.featureFlags[flag])))
      || (option.hasFeature && (!device.featureFlags || !option.hasFeature.some((flag) => device.featureFlags[flag])))
      || (option.hasProperty && !option.hasProperty.some((property) => property in device))
      || (option.modelKey && option.modelKey !== "all" && !option.modelKey.includes(device.modelKey))
      || (option.hasSmartObjectType && device.featureFlags?.smartDetectTypes && !option.hasSmartObjectType.some((type) => device.featureFlags.smartDetectTypes.includes(type))))) {
      return false;
    }
    if (device && option.isNotProperty?.some((property) => device[property] === true)) return false;
    switch (device?.modelKey) {
    case "camera": if (option.hasCameraFeature && !option.hasCameraFeature.some((flag) => device.featureFlags[flag])) return false; break;
    case "light": if (option.hasLightProperty && !option.hasLightProperty.some((property) => property in device)) return false; break;
    case "sensor": if (option.hasSensorProperty && !option.hasSensorProperty.some((property) => property in device)) return false; break;
    default: break;
    }
    return true;
  }

  const optionKey = (category, option) => category.name + (option.name ? "." + option.name : "");

  /// Whether the option has an entry at this scope.
  function isOptionModified(options, key, scopeId) {
    const pattern = scopeId
      ? new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(scopeId) + "(\\..*)?$", "i")
      : new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "(?:\\.\\d+)?$", "i");
    return options.some((entry) => pattern.test(entry));
  }

  /// The option at a scope: on or off, where that comes from, and its value.
  function getOptionState(options, key, option, scope, controllerAddress) {
    if (scope.id) {
      const pattern = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(scope.id) + "(?:\\.(\\d+))?$", "i");
      for (const entry of options) {
        const match = pattern.exec(entry);
        if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: true, scope: scope.type, value: match[2] };
      }
    }
    if (scope.type === "device" && controllerAddress) {
      const pattern = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "\\." + escapeRegex(controllerAddress) + "(?:\\.(\\d+))?$", "i");
      for (const entry of options) {
        const match = pattern.exec(entry);
        if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: false, scope: "controller", value: match[2] };
      }
    }
    const global = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + "(?:\\.(\\d+))?$", "i");
    for (const entry of options) {
      const match = global.exec(entry);
      if (match) return { enabled: match[1].toLowerCase() === "enable", explicit: scope.type === "global", scope: "global", value: match[2] };
    }
    return { enabled: option.default, explicit: false, scope: "default" };
  }

  /// The options after turning one on or off (with a value) at a scope: the entry goes only when it differs
  /// from what the scope inherits.
  function setOption(options, key, enabled, scope, option, controllerAddress, value) {
    const remove = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + (scope.id ? "\\." + escapeRegex(scope.id) : "") + "(?:\\.\\d+)?$", "i");
    const result = options.filter((entry) => !remove.test(entry));
    const inherited = option ? getOptionState(result, key, option, scope, controllerAddress) : null;
    const valueDiffers = value !== undefined && value !== option?.defaultValue;
    if (!inherited || inherited.enabled !== enabled || valueDiffers) {
      result.push((enabled ? "Enable" : "Disable") + "." + key + (scope.id ? "." + scope.id : "") + (enabled && valueDiffers ? "." + value : ""));
    }
    return result;
  }

  function removeOption(options, key, scope) {
    const remove = new RegExp("^(Enable|Disable)\\." + escapeRegex(key) + (scope.id ? "\\." + escapeRegex(scope.id) : "") + "(?:\\.\\d+)?$", "i");
    return options.filter((entry) => !remove.test(entry));
  }

  function categoryStats(options, category, entries, scope, controllerAddress) {
    let enabled = 0;
    let modified = 0;
    for (const entry of entries) {
      const key = optionKey(category, entry);
      if (getOptionState(options, key, entry, scope, controllerAddress).enabled) enabled++;
      if (isOptionModified(options, key, scope.id)) modified++;
    }
    return { enabled, modified, total: entries.length, fraction: entries.length ? enabled / entries.length : 0 };
  }

  // MARK: Camera overrides

  const normalizeMac = (mac) => (mac || "").replace(/[^0-9a-fA-F]/g, "").toLowerCase();
  const overrideFields = ["rtspUrl", "snapshotUrl", "onvifPort", "onvifUsername", "onvifPassword", "onvifServicePath"];

  /// Merges the entries of one camera into one; later non-empty values win. True when it changed anything.
  function dedupeCameraOverrides(controller) {
    if (!controller?.cameraOverrides?.length) return false;
    const merged = new Map();
    const original = controller.cameraOverrides;
    for (const entry of original) {
      const key = normalizeMac(entry?.mac || "");
      if (!key) continue;
      const existing = merged.get(key);
      if (!existing) { merged.set(key, { ...entry }); continue; }
      for (const field of overrideFields) {
        const value = entry[field];
        if (value !== undefined && value !== "") existing[field] = value;
      }
    }
    const cleaned = [...merged.values()].filter((entry) => overrideFields.some((field) => entry[field] !== undefined));
    const changed = cleaned.length !== original.length || cleaned.some((entry, index) => JSON.stringify(entry) !== JSON.stringify(original[index]));
    if (!changed) return false;
    if (cleaned.length) controller.cameraOverrides = cleaned;
    else delete controller.cameraOverrides;
    return true;
  }

  /// Sets one field of a camera's override, creating or dropping the entry.
  function updateCameraOverride(controller, mac, field, raw) {
    dedupeCameraOverrides(controller);
    const trimmed = (raw == null ? "" : String(raw)).trim();
    let value = trimmed;
    if (field === "onvifPort") {
      const parsed = trimmed === "" ? NaN : Number(trimmed);
      value = Number.isFinite(parsed) ? parsed : "";
    }
    controller.cameraOverrides ||= [];
    let entry = controller.cameraOverrides.find((candidate) => normalizeMac(candidate.mac) === normalizeMac(mac));
    if (!entry) {
      if (value === "") { if (!controller.cameraOverrides.length) delete controller.cameraOverrides; return; }
      entry = { mac };
      controller.cameraOverrides.push(entry);
    }
    if (value === "") delete entry[field];
    else entry[field] = value;
    if (!overrideFields.some((name) => entry[name] !== undefined)) controller.cameraOverrides = controller.cameraOverrides.filter((candidate) => candidate !== entry);
    if (!controller.cameraOverrides.length) delete controller.cameraOverrides;
  }

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

  const assistantDevice = (device) => ({
    adopted: device?.isAdopted, connectionType: device?.connectionType, firmware: device?.firmwareVersion, marketName: device?.marketName,
    modelKey: device?.modelKey, name: device?.name, rebooting: device?.isRebooting, state: device?.state, thirdPartyCamera: device?.isThirdPartyCamera,
    type: device?.type, updating: device?.isUpdating,
  });

  const assistantController = (controller) => ({ name: controller?.name, verifyTls: controller?.verifyTls === true });

  /// "this camera", "this light"… in the page's language.
  function thisDevice(modelKey) {
    switch (modelKey) {
    case "camera": return t("this camera");
    case "chime": return t("this chime");
    case "light": return t("this light");
    case "sensor": return t("this sensor");
    case "viewer": return t("this viewer");
    case undefined: case null: case "": return t("this device");
    default: return t("this {model}", { model: modelKey });
    }
  }

  function deviceProblem(device) {
    if (!device || device.modelKey === "nvr" || typeof device.state !== "string") return null;
    if (device.isUpdating) return t("UniFi Protect reports {device} as updating its firmware.", { device: thisDevice(device.modelKey) });
    if (device.state !== "CONNECTED") return t("UniFi Protect reports {device} as {state} (not connected).", { device: thisDevice(device.modelKey), state: device.state.toLowerCase() });
    return null;
  }

  window.ProtectOptions = {
    validOptionCategory, validOption, optionKey, isOptionModified, getOptionState, setOption, removeOption, categoryStats, normalizeMac,
    dedupeCameraOverrides, updateCameraOverride, dedupeProfilesByUrl, formatProfileLabel, scrubText, assistantDevice, assistantController, deviceProblem,
  };
})();
