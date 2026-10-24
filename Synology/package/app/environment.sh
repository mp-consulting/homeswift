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

# glibc gives each thread that allocates a heap of its own, up to eight per core, and keeps what they free. A
# camera's livestream goes through the bridge in pieces of a hundred kilobytes on whichever thread reads it, so
# the heaps grow apart; two keep the bridge's memory near what it uses.
: "${MALLOC_ARENA_MAX:=2}"
# glibc also raises the size from which it maps a block on its own to the largest block freed, up to 32 MB: after
# a recording joins a camera's buffer into one block, every snapshot and fMP4 fragment comes from the heap, which
# keeps the room between the buffer's segments. A fixed threshold maps them and gives them back.
: "${MALLOC_MMAP_THRESHOLD_:=131072}"
export MALLOC_ARENA_MAX MALLOC_MMAP_THRESHOLD_
