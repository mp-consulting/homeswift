"use strict";

// A HAP-NodeJS bridge with ACCESSORIES lightbulbs (On, Brightness, Hue, Saturation), the counterpart of
// hap-bench-server. Configured through the environment hap-bench sets: PORT, PIN, ACCESSORIES, STORAGE
// (a directory) and DEVICE_ID. HAP-NodeJS always advertises (ciao, as Homebridge does by default).

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const hap = require("@homebridge/hap-nodejs");
const { Accessory, Bridge, Categories, Characteristic, HAPStorage, Service, uuid } = hap;

const port = parseInt(process.env.PORT || "52001", 10);
const pin = process.env.PIN || "031-45-154";
const count = Math.max(1, parseInt(process.env.ACCESSORIES || "30", 10));
// Without a path HAP-NodeJS would persist into ./persist; a fresh directory keeps every run unpaired.
HAPStorage.setCustomStoragePath(process.env.STORAGE || fs.mkdtempSync(path.join(os.tmpdir(), "hap-bench-")));

const bridge = new Bridge("Bench Bridge HAP-NodeJS", uuid.generate("hap-bench.bridge"));
bridge.getService(Service.AccessoryInformation)
  .setCharacteristic(Characteristic.Manufacturer, "Bench")
  .setCharacteristic(Characteristic.Model, "Bridge");

for (let index = 1; index <= count; index++) {
  const accessory = new Accessory(`Bench Lamp ${index}`, uuid.generate(`hap-bench.lamp.${index}`));
  accessory.category = Categories.LIGHTBULB;
  accessory.getService(Service.AccessoryInformation)
    .setCharacteristic(Characteristic.Manufacturer, "Bench")
    .setCharacteristic(Characteristic.Model, "Lamp")
    .setCharacteristic(Characteristic.SerialNumber, `bench-lamp-${index}`)
    .setCharacteristic(Characteristic.FirmwareRevision, "1.0.0");
  const light = accessory.addService(Service.Lightbulb, `Bench Lamp ${index}`);
  light.setPrimaryService(true);
  for (const type of [Characteristic.On, Characteristic.Brightness, Characteristic.Hue, Characteristic.Saturation]) {
    light.getCharacteristic(type).onSet(() => {});
  }
  bridge.addBridgedAccessory(accessory);
}

bridge.publish({
  username: process.env.DEVICE_ID || "0E:BE:4C:11:22:33",
  pincode: pin,
  port,
  category: Categories.BRIDGE,
  addIdentifyingMaterial: false,
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    bridge.unpublish();
    process.exit(0);
  });
}
