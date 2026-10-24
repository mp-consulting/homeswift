#!/bin/sh
# The bridge's environment, for start.sh and the homeswift command: where its data lives, FFmpeg, and the
# system bus Avahi listens on.

PACKAGE=/var/packages/homeswift
# The shared folder the package created: config.json, the pairings, the accessory cache, logs and metrics.
HOMESWIFT_DATA="$(readlink -f "$PACKAGE/shares/homeswift")"
HOMESWIFT_BINARY="$PACKAGE/target/bin/homeswift"
# The Status page's update notice offers the .spk.
HOMESWIFT_INSTALL=synology
export HOMESWIFT_DATA HOMESWIFT_BINARY HOMESWIFT_INSTALL

# FFmpeg for cameras: the package's own (ffmpeg-for-homeswift, with libx264) goes before everything else, DSM's
# /bin/ffmpeg (4.1, without libx264, which fails every recording) included. The UniFi Protect block's
# `videoProcessor` picks another one; Entware's /opt/bin stays after the system's, as it holds more than FFmpeg.
PATH="$PACKAGE/target/bin:$PATH"
[ -d /opt/bin ] && PATH="$PATH:/opt/bin"
export PATH

# Bonjour goes through DSM's Avahi when its D-Bus socket answers; the bridge falls back to its own responder.
for socket in /run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
    if [ -S "$socket" ]; then
        export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$socket"
        break
    fi
done
export AVAHI_COMPAT_NOWARN=1
