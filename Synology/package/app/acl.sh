#!/bin/sh
# The shared folder's ACL on the bridge's secrets, for start.sh. A DSM shared folder gives each file in it the share's
# ACL (`ls -l` shows -rwxrwxrwx+), which DSM checks instead of the mode bits: other accounts with access to the share
# could read the vault's key and everything it opens. synoacltool is in /usr/syno/bin, not on a package user's PATH.
# Its -get lists a file's entries, one `[n] user:…:allow:…` line each (an inherited one says `(level:1)`), and its
# Archive line says `is_inherit` for an inherited ACL, `has_ACL` for one of its own.

SYNOACLTOOL=/usr/syno/bin/synoacltool
[ -x "$SYNOACLTOOL" ] || SYNOACLTOOL=$(command -v synoacltool)

# Whether synoacltool -get's output, on standard input, shows an ACL: an entry, or an Archive line with one.
acl_has_entries() {
    grep -Eq '^[[:space:]]*\[[0-9]+\][[:space:]]|^Archive:.*(is_inherit|has_ACL)'
}

# Removes the ACL from each file named that has one, then sets it to 0600; says on standard error which keep one.
secure_secrets() {
    for file in "$@"; do
        [ -f "$file" ] && [ ! -L "$file" ] || continue
        path=$(pwd -P)/$file
        if [ -n "$SYNOACLTOOL" ] && "$SYNOACLTOOL" -get "$path" 2> /dev/null | acl_has_entries; then
            # -del can report an error after it removed the ACL: the check after it says.
            "$SYNOACLTOOL" -del "$path" > /dev/null 2>&1
            if "$SYNOACLTOOL" -get "$path" 2> /dev/null | acl_has_entries; then
                echo "homeswift: $path keeps the shared folder's ACL, readable by other accounts with access to the share." \
                    "As root: sudo $SYNOACLTOOL -del $path; sudo $SYNOACLTOOL -get $path (no [n] entries left);" \
                    "then sudo homeswift restart. docs/synology.md, Security" >&2
            fi
        fi
        chmod 600 "$file" 2> /dev/null
    done
}
