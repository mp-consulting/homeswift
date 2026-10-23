# Homeswift on a Synology NAS

The Synology package (`homeswift-<arch>-<version>.spk`) runs the bridge on a Synology NAS, installed from
Package Center like any other: no Docker, DSM 7.0 or later, and models without Container Manager, such as the
j-series, can run it too. It is Homeswift's counterpart of
[homebridge-syno-spk](https://github.com/homebridge/homebridge-syno-spk). The container image,
`ghcr.io/mp-consulting/homeswift`, runs it with Container Manager instead.

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

UniFi Protect's cameras need FFmpeg. Install SynoCommunity's **ffmpeg7** package (or ffmpeg6), or Entware's
ffmpeg: the bridge finds them in `/var/packages/ffmpeg7/target/bin`, `/var/packages/ffmpeg6/target/bin`,
`/var/packages/ffmpeg/target/bin` or `/opt/bin`.

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
- **Camera encoding**: the package's user cannot open `/dev/dri`: FFmpeg encodes in software.
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
