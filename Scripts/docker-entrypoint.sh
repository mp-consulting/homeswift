#!/bin/sh
# The container's entrypoint (Dockerfile): Bonjour through the host's Avahi or one started here, a config.json
# with the web UI on the first run, then the bridge as $PUID:$PGID. Arguments go to homeswift.
set -eu

DATA=/homeswift
PUID=${PUID:-1000}
PGID=${PGID:-1000}
HOST_DBUS=/run/host-dbus/system_bus_socket

if [ -S "$HOST_DBUS" ]; then
    # The host's D-Bus socket is mounted: its Avahi advertises the bridge, as it does the NAS's own services.
    export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$HOST_DBUS"
    echo "homeswift: Bonjour through the host's Avahi"
else
    # Host networking shares the NAS's name; a name of our own keeps this Avahi from contending with the NAS's
    # mDNS responder for it. The bridge's records point at this name, which resolves to the NAS's addresses.
    name=${AVAHI_HOSTNAME:-$(tr -c 'A-Za-z0-9\n' '-' < /proc/sys/kernel/hostname)-homeswift}
    {
        echo "[server]"
        echo "host-name=$name"
        echo "use-ipv4=yes"
        echo "use-ipv6=yes"
        # Interfaces to advertise on, such as eth0 or ovs_eth0; every interface with multicast otherwise.
        if [ -n "${AVAHI_INTERFACES:-}" ]; then echo "allow-interfaces=$AVAHI_INTERFACES"; fi
        echo "enable-dbus=yes"
        echo "[wide-area]"
        echo "enable-wide-area=no"
        echo "[publish]"
        echo "publish-hinfo=no"
        echo "publish-workstation=no"
        echo "[reflector]"
        echo "enable-reflector=no"
        # No [rlimits]: Avahi's process limit counts the avahi user's processes on the whole host and can stop it.
    } > /etc/avahi/avahi-daemon.conf
    # The container's file system outlives a restart, and so would the pid files that stop the daemons.
    mkdir -p /run/dbus /run/avahi-daemon
    rm -f /run/dbus/pid /run/avahi-daemon/pid
    dbus-uuidgen --ensure
    dbus-daemon --system --fork
    avahi-daemon --daemonize --no-chroot
    # Avahi refuses registrations while it probes its name, and the bridge would stop on that. Resolving the
    # name returns once the probe is over.
    tries=0
    until avahi-resolve-host-name -4 "$name.local" > /dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -ge 10 ]; then
            echo "homeswift: Avahi has not answered for $name.local; starting anyway" >&2
            break
        fi
        sleep 1
    done
fi

mkdir -p "$DATA"
if [ ! -f "$DATA/config.json" ]; then
    # The bridge generates its username and setup code on the first launch and keeps them. The web UI is the
    # only way to configure a bridge in a container, so it is on from the start; the first account needs the
    # set-up code that the log's banner prints.
    cat > "$DATA/config.json" <<'EOF'
{
  "bridge": {
    "name": "Homeswift",
    "port": 51826
  },
  "accessories": [],
  "platforms": [
    { "platform": "HomeswiftUI" }
  ]
}
EOF
    chmod 600 "$DATA/config.json"
    echo "homeswift: created $DATA/config.json with the web UI on port 8581"
fi
# A folder made in File Station belongs to its DSM user; the bridge needs it as its own.
if [ "$(stat -c %u:%g "$DATA")" != "$PUID:$PGID" ]; then
    chown -R "$PUID:$PGID" "$DATA"
fi

# D-Bus turns away a uid without an account, and Avahi with it: a DSM uid such as 1026 has none in the image.
if ! getent group "$PGID" > /dev/null; then
    echo "homeswift:x:$PGID:" >> /etc/group
fi
if ! getent passwd "$PUID" > /dev/null; then
    echo "homeswift:x:$PUID:$PGID::$DATA:/usr/sbin/nologin" >> /etc/passwd
fi

export HOME="$DATA"
exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups /usr/local/bin/homeswift -U "$DATA" "$@"
