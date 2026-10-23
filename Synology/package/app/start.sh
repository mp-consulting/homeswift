#!/bin/sh
# Started by systemd as the package's user (conf/systemd/pkguser-homeswift.service). The output goes to the
# journal; the log the web UI and `homeswift logs` show is under logs/ in the shared folder.

. /var/packages/homeswift/target/app/environment.sh
. /var/packages/homeswift/target/app/ports.sh

cd "$HOMESWIFT_DATA" || exit 1

# DSM's main menu opens the web UI where config.json puts it (port, HTTPS), not where it was installed.
ui=$(jq -r '[.platforms[]? | select(.platform == "HomeswiftUI")][0] // empty
    | "\(if .https == true then "https" else "http" end) \(.port // 8581)"' config.json 2> /dev/null)
if [ -n "$ui" ]; then
    write_ui_config /var/packages/homeswift/target/ui ${ui% *} ${ui#* }
fi

exec "$HOMESWIFT_BINARY" -U "$HOMESWIFT_DATA"
