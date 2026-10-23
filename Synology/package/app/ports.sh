#!/bin/sh
# The ports DSM knows about: the main menu's link to the web UI (ui/config) and the firewall's entries
# (app/homeswift.sc). The install wizard picks them (scripts/preinst), and start.sh keeps the link on the
# web UI's port and scheme when config.json changes them.

# Whether something listens on TCP port $1.
port_in_use() {
    hex=$(printf ':%04X' "$1")
    awk -v port="$hex" '$4 == "0A" && substr($2, length($2) - 4) == port { found = 1 } END { exit !found }' \
        /proc/net/tcp /proc/net/tcp6 2> /dev/null
}

# What listens on TCP port $1, when the process can be seen; empty otherwise.
port_owner() {
    hex=$(printf ':%04X' "$1")
    inode=$(awk -v port="$hex" '$4 == "0A" && substr($2, length($2) - 4) == port { print $10; exit }' /proc/net/tcp /proc/net/tcp6 2> /dev/null)
    [ -n "$inode" ] || return 0
    for fd in /proc/[0-9]*/fd/*; do
        if [ "$(readlink "$fd" 2> /dev/null)" = "socket:[$inode]" ]; then
            pid=${fd#/proc/}
            tr '\0' ' ' < "/proc/${pid%%/*}/cmdline" 2> /dev/null | cut -c1-80
            return 0
        fi
    done
}

# Writes the main menu's link to the web UI: write_ui_config <ui directory> <http|https> <port>.
write_ui_config() {
    cat > "$1/config.new" <<JSON
{
    ".url": {
        "homeswift.homeswift": {
            "title": "Homeswift",
            "desc": "Homeswift web UI",
            "icon": "images/icon_256.png",
            "type": "url",
            "protocol": "$2",
            "port": "$3",
            "url": "/",
            "allUsers": true,
            "grantPrivilege": "local"
        }
    }
}
JSON
    if cmp -s "$1/config.new" "$1/config"; then rm -f "$1/config.new"; else mv "$1/config.new" "$1/config"; fi
}

# Writes the firewall's entries: write_firewall <file> <HomeKit port> <web UI port>.
write_firewall() {
    cat > "$1" <<SC
[homeswift_hap]
title="Homeswift (HomeKit)"
desc="Homeswift bridge"
port_forward="no"
dst.ports="$2/tcp"

[homeswift_ui]
title="Homeswift web UI"
desc="Homeswift web UI"
port_forward="no"
dst.ports="$3/tcp"
SC
}
