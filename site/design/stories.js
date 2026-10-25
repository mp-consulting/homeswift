// Stories use the generated HAP contracts and the real production renderer.
(() => {
  const { characteristics, services } = HomeswiftDesignCatalog;
  const byID = new Map(characteristics.map((one) => [one.id, one]));
  const security = new Set(["lockTargetState", "targetDoorState", "securitySystemTargetState"]);
  const defaults = { on: true, active: 1, brightness: 75, hue: 35, saturation: 65, colorTemperature: 250,
    currentTemperature: 21.5, targetTemperature: 22, currentRelativeHumidity: 48, batteryLevel: 82,
    currentHeaterCoolerState: 2, targetHeaterCoolerState: 1, heatingThresholdTemperature: 22, coolingThresholdTemperature: 24,
    currentAirPurifierState: 2, targetAirPurifierState: 1, airQuality: 1, rotationSpeed: 40, targetFanState: 1, currentFanState: 2,
    currentPosition: 60, targetPosition: 60, positionState: 2, currentDoorState: 1, targetDoorState: 1,
    lockCurrentState: 1, lockTargetState: 1, securitySystemCurrentState: 3, securitySystemTargetState: 3,
    setDuration: 600, remainingDuration: 0, valveType: 1, filterLifeLevel: 85, activeIdentifier: 1, configuredName: "Demo accessory" };
  function characteristic(id, value) {
    const definition = byID.get(id);
    if (!definition) throw new Error(`Unknown characteristic: ${id}`);
    const fallback = definition.format === "bool" ? false : definition.format === "string" ? "Demo value"
      : ["tlv8", "data"].includes(definition.format) ? "" : definition.validValues?.[0] ?? definition.minValue ?? 0;
    return { ...structuredClone(definition), security: security.has(id), value: value ?? defaults[id] ?? fallback };
  }
  function service(id, ids, primary = true, extra = {}) {
    const definition = services.find((one) => one.id === id);
    return { type: definition.name, name: definition.name, primary, characteristics: ids.map((id) => characteristic(id)), ...extra };
  }
  const specs = [
    ["light", "Light", "Brightness, colour and white temperature.", "lightbulb", [["lightbulb", ["on", "brightness", "hue", "saturation", "colorTemperature"]]]],
    ["climate", "Climate", "Temperature, setpoints and heating or cooling modes.", "airConditioner", [["heaterCooler", ["active", "currentHeaterCoolerState", "targetHeaterCoolerState", "currentTemperature", "heatingThresholdTemperature", "coolingThresholdTemperature", "rotationSpeed", "swingMode"]]]],
    ["air-purifier", "Air purifier", "Air quality, speed, modes and filter life.", "airPurifier", [["airPurifier", ["active", "currentAirPurifierState", "targetAirPurifierState", "rotationSpeed"]], ["airQualitySensor", ["airQuality"]], ["humiditySensor", ["currentRelativeHumidity"]], ["filterMaintenance", ["filterLifeLevel", "filterChangeIndication"]]]],
    ["fan", "Fan", "Speed, direction, modes and swing.", "fan", [["fanv2", ["active", "currentFanState", "targetFanState", "rotationSpeed", "rotationDirection", "swingMode"]]]],
    ["cover", "Shutter", "Position, tilt and a direct manipulation shade.", "windowCovering", [["windowCovering", ["currentPosition", "targetPosition", "positionState", "holdPosition", "currentHorizontalTiltAngle", "targetHorizontalTiltAngle"]]]],
    ["gate", "Gate", "Hold to open; tap to close.", "garageDoorOpener", [["garageDoorOpener", ["currentDoorState", "targetDoorState", "obstructionDetected"]]]],
    ["lock", "Lock", "Hold to unlock; tap to lock.", "doorLock", [["lockMechanism", ["lockCurrentState", "lockTargetState"]]]],
    ["alarm", "Alarm", "Arming modes and a deliberate disarm action.", "securitySystem", [["securitySystem", ["securitySystemCurrentState", "securitySystemTargetState"]]]],
    ["valve", "Valve", "A timed run with a countdown and duration choices.", "sprinkler", [["valve", ["active", "inUse", "valveType", "setDuration", "remainingDuration"]]]],
    ["switch", "Switch", "A simple power action and clear on/off state.", "outlet", [["outlet", ["on", "outletInUse"]]]],
    ["switch-group", "Switch group", "Multiple independent switches in one accessory.", "switch", [["switch", ["on"]], ["switch", ["on"]], ["switch", ["on"]]]],
    ["sensor", "Sensor", "Readings with units, quality states and battery life.", "sensor", [["temperatureSensor", ["currentTemperature"]], ["humiditySensor", ["currentRelativeHumidity"]], ["battery", ["batteryLevel", "statusLowBattery", "chargingState"]]]],
    ["television", "Television", "Inputs, volume and remote keys.", "television", [["television", ["active", "activeIdentifier", "remoteKey"]], ["televisionSpeaker", ["mute", "volumeSelector", "volumeControlType"]]]],
    ["camera", "Camera", "A demonstration still using the real camera view.", "ipCamera", [["motionSensor", ["motionDetected"]]]],
  ];
  const widgets = specs.map(([id, name, description, category, definitions]) => ({ id: `widget/${id}`, kind: "widget", name, description, category,
    build() {
      const accessory = { id: `Design:${id}`, name: `Demo ${name}`, category, manufacturer: "Homeswift", model: "Design preview", platformName: "Demo", services: definitions.map(([key, ids], index) => service(key, ids, index === 0, { subtype: `${key}-${index}` })) };
      if (id === "camera") accessory.camera = true;
      if (id === "switch-group") accessory.services.forEach((one, index) => { one.name = `Switch ${index + 1}`; one.characteristics[0].value = index === 0; });
      if (id === "television") for (let index = 1; index <= 2; index++) accessory.services.push(service("inputSource", ["identifier", "configuredName", "currentVisibilityState"], false, { name: `HDMI ${index}`, subtype: `input-${index}`, characteristics: [characteristic("identifier", index), characteristic("configuredName", `HDMI ${index}`), characteristic("currentVisibilityState", 0)] }));
      return accessory;
    },
  }));
  function rowStory(id) {
    const c = characteristic(id);
    const owner = services.find((one) => one.id === c.services[0]);
    const accessory = { id: `Design:${id}`, name: "Demo accessory", category: "other", services: [{ type: owner?.name || "Custom", primary: true, subtype: "preview", characteristics: [c] }] };
    if (id === "activeIdentifier") for (let value = 1; value <= 2; value++) accessory.services.push(service("inputSource", [], false, { subtype: `input-${value}`, characteristics: [characteristic("identifier", value), characteristic("configuredName", `HDMI ${value}`)] }));
    return accessory;
  }
  window.HomeswiftDesignStories = { widgets, characteristic, rowStory, byID };
})();
