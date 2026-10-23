// Merges the setup wizard's output into this instance's saved block, as the Homebridge plugin's
// config-merge.js: the wizard renders only part of the block, so the keys it does not write are kept
// (isSingleAccessoryModeEnabled, enableHeater, _bridge, per-device overrides), and `devices` follows the
// wizard's list, each entry matched to the saved one by serial number.
(function (root) {
  "use strict";
  // Per-device keys the wizard edits: when it leaves one out, the user turned it off or reset it, so a
  // saved value must not come back.
  const WIZARD_DEVICE_SETTINGS = ["isContinuousMonitoringEnabled", "heatingServiceType", "temperatureOffset", "humidityOffset", "useFahrenheit"];

  const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  const withoutUndefined = (object) => Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));

  function savedDevicesBySerial(savedDevices) {
    const bySerial = new Map();
    for (const device of Array.isArray(savedDevices) ? savedDevices : []) {
      if (isObject(device) && typeof device.serial === "string" && !bySerial.has(device.serial)) bySerial.set(device.serial, device);
    }
    return bySerial;
  }

  function mergeDevice(saved, built) {
    const kept = { ...saved };
    for (const key of WIZARD_DEVICE_SETTINGS) delete kept[key];
    return { ...kept, ...withoutUndefined(built) };
  }

  /// The block to save: `existing` (the saved block, may be undefined) updated with `built` (the wizard's fields).
  function mergePluginConfig(existing, built) {
    const base = isObject(existing) ? existing : {};
    const saved = savedDevicesBySerial(base.devices);
    const devices = (Array.isArray(built.devices) ? built.devices : []).map((device) => {
      const savedDevice = saved.get(device.serial);
      return savedDevice ? mergeDevice(savedDevice, device) : withoutUndefined(device);
    });
    return { ...base, ...withoutUndefined(built), devices };
  }

  /// Devices fetched from the Dyson cloud carry no wizard settings: the saved ones (offsets, heating service…)
  /// are copied onto them by serial, so a re-sync does not reset them.
  function withSavedDeviceSettings(cloudDevices, savedDevices) {
    const saved = savedDevicesBySerial(savedDevices);
    return (Array.isArray(cloudDevices) ? cloudDevices : []).map((device) => {
      const savedDevice = isObject(device) ? saved.get(device.serial) : undefined;
      if (!savedDevice) return device;
      const settings = {};
      for (const key of WIZARD_DEVICE_SETTINGS) {
        if (savedDevice[key] !== undefined && device[key] === undefined) settings[key] = savedDevice[key];
      }
      return { ...device, ...settings };
    });
  }

  root.DysonConfigMerge = { mergePluginConfig, withSavedDeviceSettings, WIZARD_DEVICE_SETTINGS };
})(globalThis);
