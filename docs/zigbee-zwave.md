# Zigbee and Z-Wave

Homeswift reaches Zigbee and Z-Wave devices through the two projects that know them best, rather than talking to the
USB stick itself: **Zigbee2MQTT** (thousands of Zigbee devices, each with its own fixes) over an MQTT broker, and
**zwave-js-server** (Z-Wave JS, the driver Home Assistant uses) over a WebSocket. They run beside the bridge; you add
devices from the web UI's **Add accessories** page, and never need their own pages for it.

## With Docker (Synology Container Manager or any Linux server)

docker-compose.yml has them as optional services, all on host networking like the bridge:

| Profile | Services | What they do |
|---|---|---|
| `zigbee` | `mosquitto`, `zigbee2mqtt` | The MQTT broker, answering on the NAS itself only (localhost:1883), and Zigbee2MQTT on your Zigbee stick |
| `zwave` | `zwave-js` | zwave-js-server on your Z-Wave stick, port 3000, announced over mDNS |

1. Find your stick's name: `ls /dev/serial/by-id` over SSH, or the Status page's Homeswift card once the bridge runs. Put it in the service's `devices:` line, before the colon.
2. For Zigbee, name the stick's chip in `ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER` when Zigbee2MQTT does not recognise it:
   `ember` (Sonoff Dongle-E, Home Assistant SkyConnect and Connect ZBT-1), `zstack` (Sonoff Dongle-P), `deconz` (ConBee).
3. For Z-Wave, make the network keys once (below) and set `RF_REGION` to your region.
4. Start them: `docker compose --profile zigbee --profile zwave up -d`. In Container Manager, delete the `profiles:`
   lines of the services you want, then build the project.

Create the folders the volumes name first (`/volume1/docker/mosquitto`, `zigbee2mqtt`, `zwave-js/cache`).

### Z-Wave keys

A Z-Wave network's devices are secured with keys zwave-js-server keeps in `zwave.env`. Make them once, on the NAS:

```sh
mkdir -p /volume1/docker/zwave-js && cd /volume1/docker/zwave-js
for key in S2_ACCESS_CONTROL_KEY S2_AUTHENTICATED_KEY S2_UNAUTHENTICATED_KEY S0_LEGACY_KEY LR_S2_ACCESS_CONTROL_KEY LR_S2_AUTHENTICATED_KEY; do
  echo "$key=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | tr a-f A-F)"
done > zwave.env && chmod 600 zwave.env
```

Keep a copy somewhere safe: without them, the secured devices must be included again. Never share them.

## In Homeswift

1. **Plugins** → add **Zigbee2MQTT** and **Z-Wave JS**.
2. **Add accessories** → Zigbee2MQTT: its broker is `mqtt://localhost:1883` and its base topic `zigbee2mqtt`, as
   Setup proposes. Z-Wave JS: **Add a Z-Wave device…** finds zwave-js-server on the network; check it is yours.
3. **Add a Zigbee device…** lets devices join for two minutes: reset the device, or hold its button until its light
   blinks. Setup is done once Zigbee2MQTT has read what it does.
4. **Add a Z-Wave device…** includes one into the network: put it in inclusion mode (often three presses of its
   button). A lock or a garage door asks for the five-digit PIN printed on it or its box. **Remove a device from the
   network**, among its choices, takes one out (an exclusion), also from another network it was in.

The Status page's Homeswift card lists the Zigbee and Z-Wave sticks plugged in, by the names to put in the `devices:`
lines. In the container it sees them once docker-compose.yml's `/dev/serial/by-id` line is turned on.

Each device then shows as an accessory, in the Home app and on the wall, like any other.

## Elsewhere

On a Mac or a server without Docker, run Zigbee2MQTT (with Mosquitto) and zwave-js-server, or Z-Wave JS UI with its
**WS Server** turned on, as their own documentation says; Homeswift connects to them the same way. Home Assistant's
Zigbee2MQTT and Z-Wave JS add-ons work too: point Setup at Home Assistant's broker and at its port 3000.

## What stays in their own pages

Firmware updates, network maps and a Z-Wave device's configuration parameters:
Zigbee2MQTT's page (port 8099 in docker-compose.yml) and Z-Wave JS UI do these. Forgetting a device in Homeswift
only forgets it here: it stays in its network.
