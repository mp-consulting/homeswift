#!/bin/sh
# Started by systemd as the package's user (conf/systemd/pkguser-homeswift.service). The output goes to the
# journal; the log the web UI and `homeswift logs` show is under logs/ in the shared folder.

. /var/packages/homeswift/target/app/environment.sh

cd "$HOMESWIFT_DATA" || exit 1
exec "$HOMESWIFT_BINARY" -U "$HOMESWIFT_DATA"
