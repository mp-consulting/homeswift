# Homeswift on a Synology NAS

Two ways to run the bridge on a Synology NAS:

- **The package** (`homeswift-<arch>-<version>.spk`), installed from Package Center like any other: no Docker,
  DSM 7.0 or later, and models without Container Manager, such as the j-series, can run it too. It is
  Homeswift's counterpart of [homebridge-syno-spk](https://github.com/homebridge/homebridge-syno-spk).
- **The container** from `ghcr.io/mp-consulting/homeswift`, with Container Manager on DSM 7.2 or later.

## The package

Packages are built for 64-bit models: **x86_64** (Intel and AMD: the plus, xs and value series) and
**aarch64** (64-bit ARM: DS118, DS218, DS418, DS220j, DS420j, DS223, DS223j, DS423, DS124, DS120j, DS119j,
RS819 and the other Realtek RTD1296/RTD1619B and Marvell Armada 37xx models). Synology's
[CPU list](https://kb.synology.com/en-global/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have) says which a
model has. 32-bit ARM models (armv7: DS216j, DS218j, DS416…) cannot run Swift, and so cannot run Homeswift.

### Install

1. Download the `.spk` for your model's architecture from the
   [latest release](https://github.com/mp-consulting/homeswift/releases/latest).
2. In **Package Center**, click **Manual Install** and choose the file. DSM warns that the package is from an
   unknown publisher: click **Agree**.
3. The wizard asks for the **web UI's administrator account**: a username and a password of at least 12
   characters that is not a common word. A password that is too weak is refused with the reason before
   anything is installed.
4. The **Ports** step proposes `8581` for the web UI and `51826` for the HomeKit bridge. A port another
   service listens on, such as a Homebridge on the same NAS, is refused with the reason before anything is
   installed; go back and pick another. The same step asks for **HTTPS** (the default) or **HTTP**. HTTPS
   keeps the password and session private on the network, and Safari allows the Assistant's microphone only
   over HTTPS; the bridge makes its own certificate, so the browser warns once (or install it from
   `/homeswift-ui.crt` to trust it). HTTP sends everything in the clear.
5. Once installed, **Homeswift** is in DSM's main menu: it opens the web UI on the port and scheme you chose. Sign in, add
   plugins on the **Plugins** page, then add the bridge in the Home app: scan the QR code on the **Status**
   page, or **Add Accessory > More options**, **Homeswift**, and the setup code.

The package creates:

| What | Where |
|---|---|
| The **homeswift** shared folder | `config.json`, the pairings, the accessory cache, `logs/` and `metrics/`. Back it up with Hyper Backup; it survives an uninstall |
| The **homeswift** user | The bridge runs as this user, not as root (DSM 7 packages cannot) |
| The bridge | `/var/packages/homeswift/target/bin/homeswift`, a systemd unit DSM restarts if it stops |
| The `homeswift` command | Over SSH, see below |

On the first install, `config.json` has the bridge and the web UI on the wizard's ports (and `"https"` as
chosen), and DSM's firewall
entries name them. The bridge generates and keeps its device ID and setup code. An upgrade or a reinstall
leaves the shared folder as it is.

When a new release is out, the web UI's **Status** page says so, with a **Download the package** button for
the NAS's architecture: install it with **Package Center > Manual Install**, which upgrades in place. Package
Center itself does not watch GitHub, and the bridge cannot upgrade itself (DSM runs it as its own user).

When the web UI moves (another `port`, or `"https": true` in its block), the page you are on cannot follow it:
open the new address yourself. DSM's menu entry follows at the package's next start
(**Package Center > Homeswift > Stop**, then **Run**). Do not paste a whole config.json from another bridge:
its `bridge` block holds that bridge's HomeKit identity (`username`, `pin`), and two bridges with one
identity make the Home app drop the pairing. Copy the `platforms` instead.

### Over SSH

`homeswift` runs the bridge's binary as the package's user, on the package's data. It needs `sudo`:

```bash
sudo homeswift logs -f                    # the log, as the web UI's Logs page shows it
sudo homeswift restart                    # also start, stop and status
sudo homeswift users password admin       # a forgotten web UI password: type a new one
sudo homeswift users add alice            # another account; restart for the web UI to know it
sudo homeswift ask "Why is the TV not responding?"
```

### Bonjour

HomeKit finds the bridge over mDNS. The package asks DSM's Avahi to advertise it when the bridge can reach
it over D-Bus; otherwise the bridge advertises itself with its built-in responder and says so in its log
(`Bonjour unavailable (…); advertising with the built-in mDNS responder`). It shares UDP port 5353 with DSM's
Avahi and advertises under a host name of its own, `Homeswift.local`, so it never contends with the NAS's name.
Both work with the Home app; to choose the built-in responder whatever happens, or to keep it to some
interfaces (a NAS on two networks, or with Open vSwitch for Virtual Machine Manager), set Homebridge's options
in config.json's bridge block:

```json
"bridge": { "name": "Homeswift", "port": 51826, "advertiser": "ciao", "bind": ["ovs_eth0"] }
```

`bind` takes interface names or IPv4 addresses. The [Firewall](#firewall) section applies to both.

### FFmpeg

The package includes FFmpeg for UniFi Protect's cameras: `bin/ffmpeg`, the static
[ffmpeg-for-homeswift](../FFmpeg/README.md) the container image has (FFmpeg 8.1 with libx264, Opus and OpenSSL), and its
licences in `share/doc/ffmpeg-for-homeswift`. The bridge uses it before DSM's own `/bin/ffmpeg` (4.1, without libx264,
which cannot encode HomeKit Secure Video recordings). To use another FFmpeg, such as SynoCommunity's ffmpeg7, set the
UniFi Protect block's `videoProcessor` to its path (`/var/packages/ffmpeg7/target/bin/ffmpeg`). The log warns at start
when the FFmpeg in use has no libx264.

### Moving to the package

From a Mac, or from the container: stop the old bridge and keep it stopped (two bridges advertising the same
device ID make the Home app drop the pairings), install the package, stop it in Package Center, copy the old
data folder's contents (the Mac's `~/.homeswift`, the container's `docker/homeswift`) into the **homeswift**
shared folder, replacing what is there, and start the package. The Home app keeps the bridge, its rooms and
automations. The copied `ui-users.json` brings the old web UI accounts with it.

### Building the package

`Synology/build.sh` builds both packages into `.build/synology/` with Docker, on macOS or Linux; no
Synology toolchain is needed. The binary is built on Amazon Linux 2, whose glibc is DSM 7.0's, with the Swift
runtime linked in and Avahi's dns_sd library beside it. Pushing a release tag runs
`.github/workflows/synology.yml`, which attaches both packages to the release.

```bash
Synology/build.sh aarch64        # or x86_64; both without an argument
```

## The container

The bridge runs as a container from `ghcr.io/mp-consulting/homeswift`, the image the
[Dockerfile](../Dockerfile) builds. The image is published for `linux/amd64` (Intel and AMD models) and
`linux/arm64`, and Docker pulls the right one. You need DSM 7.2 or later with **Container Manager** from the
Package Center. Synology's package page lists the models that can run it.

The same image and [docker-compose.yml](../docker-compose.yml) work on any Linux server with Docker.

### Install

1. In **File Station**, create the folder `docker/homeswift` (the `docker` shared folder is created by
   Container Manager). It holds `config.json`, the pairings, the accessory cache, the logs and the metrics.
2. Over SSH, `id` shows your DSM user's uid and gid. The compose file uses `1026` and `100`, the first account
   DSM creates and its `users` group; change `PUID` and `PGID` if yours differ, and `TZ` to your time zone.
3. In **Container Manager > Project > Create**, name the project `homeswift`, choose `/docker/homeswift` as
   the path, pick **Upload docker-compose.yml** (or **Create docker-compose.yml** and paste it), and finish.
   The image is pulled and the container starts.
4. Open **Container > homeswift > Log**. The banner prints the bridge's HomeKit setup code, the web UI's
   address and, until an account exists, the web UI's set-up code.
5. Open `http://<nas-address>:8581`, create the administrator account with that set-up code, and add
   plugins on the **Plugins** page. Then add the bridge in the Home app: scan the QR code on the **Status**
   page, or **Add Accessory > More options**, **Homeswift**, and the setup code.

On the first start the container writes a `config.json` with the bridge on port `51826` and the web UI on
`8581` ([docs/ui.md](ui.md)). The bridge generates and keeps its device ID and setup code. If `config.json`
exists already, it is left as it is.

Over SSH instead of Container Manager, in a folder holding `docker-compose.yml`:

```bash
sudo docker compose up -d
```

### What the compose file sets

| Setting | Why |
|---|---|
| `network_mode: host` | Required. HomeKit finds the bridge over mDNS multicast, which a bridged container network does not carry, and connects to the bridge's port on the NAS's address. With host networking there are no ports to map |
| `restart: unless-stopped` | The bridge comes back after a reboot or a crash. A restart from the web UI happens inside the container, which keeps running |
| `stop_grace_period: 30s` | Time to stop the servers and the plugins and to write the accessory cache |
| `PUID`, `PGID` | The user the bridge runs as. The container makes the data folder that user's, so you can read and back up the files from DSM |
| `TZ` | The time zone of the log and of the Logs page's days |
| `AVAHI_INTERFACES` | Advertise only on these interfaces, such as `eth0`, or `ovs_eth0` when Open vSwitch is on for Virtual Machine Manager. By default every interface with multicast is used |
| `/volume1/docker/homeswift:/homeswift` | The data. Change `volume1` if the shared folder lives on another volume |

### Bonjour (container)

Homeswift advertises through Avahi on Linux. By default the container runs its own Avahi daemon under its own
name, `<nas-name>-homeswift.local`, which resolves to the NAS's addresses. It does not contend with DSM's
own mDNS responder for the NAS's name. Avahi may log that it detected another mDNS stack on the host; with
the two names apart, both work.

DSM runs Avahi too, for its Bonjour service discovery (**Control Panel > File Services > Advanced**). To
have DSM's Avahi advertise the bridge instead, check over SSH that its D-Bus socket exists:

```bash
ls -l /run/dbus/system_bus_socket
```

Then uncomment the `/run/dbus/system_bus_socket:/run/host-dbus/system_bus_socket` volume in the compose
file. The container then starts no daemon and says `Bonjour through the host's Avahi` in its log. This
depends on DSM's Avahi and its D-Bus policy, which Synology can change in an update; the built-in daemon is the
default because it does not.

To see what is advertised:

```bash
sudo docker exec homeswift avahi-browse -rt _hap._tcp
```

### Updating

In **Container Manager > Project > homeswift**, **Action > Stop**, then **Action > Build**, which pulls the
current image and starts the container again. Over SSH:

```bash
sudo docker compose pull && sudo docker compose up -d
```

To stay on one release, replace `latest` with a version such as `0.3.0`, or with `0.3` for its patch releases.
The pairings live in the data folder, so the Home app keeps the bridge, its rooms and automations across
updates.

### Moving a bridge from a Mac

Stop the bridge on the Mac first and keep it stopped: two bridges advertising the same device ID make the
Home app drop the pairings. Then copy the contents of the Mac's `~/.homeswift` into `docker/homeswift` and
start the container. The Home app keeps the bridge as it is. Paths in config.json that point at the Mac's file
system, such as a certificate for the web UI, need to be changed.

## Firewall

If the DSM firewall is on (**Control Panel > Security > Firewall**), allow from your local network:

- UDP `5353`, for mDNS;
- TCP `51826`, the bridge (the `port` in config.json's `bridge` block);
- TCP `8581`, the web UI;
- the port of each child bridge and of each accessory published on its own (televisions, cameras). They
  appear on the Status page. Give them fixed ports in config.json so the rule does not change.

With the package, the firewall's list of applications has **Homeswift (HomeKit)** and **Homeswift web UI**
for the default ports, and DSM's own **Bonjour** service for UDP 5353.

## Limits

- **Bluetooth**: the Govee plugin's Bluetooth goes through CoreBluetooth, which only macOS has. On a NAS the
  Govee plugin works through the LAN and the cloud only.
- **Camera encoding**: the image includes FFmpeg for UniFi Protect cameras. On an Intel NAS with Quick
  Sync, uncomment the `/dev/dri` device in the compose file to let FFmpeg use the hardware encoder. The
  package's user cannot open `/dev/dri`: FFmpeg encodes in software there.
- **Package Center sources**: the package is installed by hand (**Manual Install**); updates come the same
  way, with the next release's `.spk`.
- **Hostnames in the web UI**: the UI answers to IP addresses, `localhost` and the NAS's name. Add a DNS
  name or a reverse proxy's host to `allowedHosts` ([docs/ui.md](ui.md)).

## Troubleshooting

- **The package does not start**: `sudo homeswift logs` shows the bridge's log, and
  `sudo journalctl -u pkguser-homeswift` (or `sudo synosystemctl status pkguser-homeswift`) what systemd saw.
- **The Home app does not find the packaged bridge**: check that the iPhone is on the same network as the NAS
  (not a guest Wi-Fi) and the firewall rules above. The log says whether Avahi or the built-in responder
  advertises it; on a NAS with several interfaces, `bind` keeps the built-in responder to the LAN's.
- **The Home app does not find the bridge**: check that the container uses host networking, that the iPhone is
  on the same network as the NAS (not a guest Wi-Fi), the firewall rules above, and `avahi-browse`. On a NAS
  with several interfaces or with Open vSwitch on, set `AVAHI_INTERFACES` to the LAN's interface.
- **`homeswift: could not create /homeswift/config.json`**: the folder is on a volume the container cannot
  write. Check the path in the compose file.
- **Commands**: the binary is `homeswift` in the container. Run it as the bridge's user, so that files it
  writes stay readable to the bridge, and pass the data folder:

  ```bash
  sudo docker exec -it -u 1026:100 homeswift homeswift -U /homeswift ask "Why is the TV not responding?"
  ```
