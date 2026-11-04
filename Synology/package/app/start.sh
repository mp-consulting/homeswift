#!/bin/sh
# Started by systemd as the package's user (conf/systemd/pkguser-homeswift.service). The output goes to the
# journal; the log the web UI and `homeswift logs` show is under logs/ in the shared folder.

. /var/packages/homeswift/target/app/environment.sh
. /var/packages/homeswift/target/app/ports.sh

cd "$HOMESWIFT_DATA" || exit 1

# The shared folder gives each file in it the share's ACL (`ls -l` shows -rwxrwxrwx+), which DSM checks instead of
# the mode bits: other accounts with access to the share could read the vault's key and everything it opens. The
# bridge's secrets lose that ACL and are the bridge's alone (0600); the bridge checks again and warns in its log
# about what stays open. synoacltool -get prints "Archive: has_ACL,…" for a file with an ACL, -del <path> removes it.
secure_secrets() {
    acl=$(command -v synoacltool || echo /usr/syno/bin/synoacltool)
    for file in secrets.key vault.json config.json homeswift.json ui-users.json ui-sessions.json ui-oauth.json \
        ui-api-tokens.json ui-key.pem; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        if [ -x "$acl" ] && "$acl" -get "$PWD/$file" 2> /dev/null | grep -q has_ACL; then
            # -del can report an error after it removed the ACL: the check after it says.
            "$acl" -del "$PWD/$file" > /dev/null 2>&1
            if "$acl" -get "$PWD/$file" 2> /dev/null | grep -q has_ACL; then
                echo "homeswift: $PWD/$file keeps the shared folder's ACL; see docs/synology.md, Security" >&2
            fi
        fi
        chmod 600 "$file" 2> /dev/null
    done
}

# DSM's main menu opens the web UI where config.json puts it (port, HTTPS), not where it was installed.
ui=$(jq -r '[.platforms[]? | select(.platform == "HomeswiftUI")][0] // empty
    | "\(if .https == true then "https" else "http" end) \(.port // 8581)"' config.json 2> /dev/null)
# Written into the menu's JSON: a scheme and a port number, or nothing.
case ${ui#* } in
    '' | *[!0-9]*) ui= ;;
esac
if [ -n "$ui" ]; then
    write_ui_config /var/packages/homeswift/target/ui "${ui% *}" "${ui#* }"
fi

secure_secrets

exec "$HOMESWIFT_BINARY" -U "$HOMESWIFT_DATA"
