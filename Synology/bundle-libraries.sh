#!/bin/sh
# Copies the shared libraries the binary needs and DSM lacks into <out>/lib (Synology/Dockerfile), and fails on
# a dependency that is neither bundled nor known to be part of DSM 7.
set -eu

OUT=$1
mkdir -p "$OUT/lib"

# Avahi's dns_sd compatibility layer, its client and D-Bus: DSM runs Avahi but does not ship the compatibility
# library, and its own libraries are not a stable interface.
BUNDLED='libdns_sd|libavahi-client|libavahi-common|libdbus-1'
# glibc and the libraries every DSM 7 has in /usr/lib (libsystemd: DSM 7 runs on systemd; libdbus links it).
SYSTEM='linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread|librt\.so|libutil|libresolv|libstdc\+\+|libgcc_s|libcurl|libz\.so|libsystemd'

# The libraries a file names itself (NEEDED), not ldd's whole closure: a system library brings its own.
copy_needed() {
    for name in $(objdump -p "$1" | awk '$1 == "NEEDED" { print $2 }'); do
        path=$(ldd "$1" | awk -v name="$name" '$1 == name { print $3 }')
        if echo "$name" | grep -Eq "^($BUNDLED)"; then
            if [ ! -e "$OUT/lib/$name" ]; then
                cp -L "$path" "$OUT/lib/$name"
                copy_needed "$path"
            fi
        elif ! echo "$name" | grep -Eq "^($SYSTEM)"; then
            echo "bundle-libraries: $1 needs $name ($path), which is neither bundled nor part of DSM" >&2
            exit 1
        fi
    done
}

# RUNPATH would apply to the binary's own dependencies only, and dns_sd would not find avahi-client.
objdump -p "$OUT/bin/homeswift" | grep -Eq '^ *RPATH .*\$ORIGIN/\.\./lib' || {
    echo "bundle-libraries: the binary has no DT_RPATH \$ORIGIN/../lib:" >&2
    objdump -p "$OUT/bin/homeswift" | grep -E 'R(UN)?PATH' >&2
    exit 1
}
copy_needed "$OUT/bin/homeswift"
chmod 644 "$OUT"/lib/*
strip --strip-unneeded "$OUT"/lib/*
echo "bundle-libraries: $(cd "$OUT/lib" && echo *)"
echo "bundle-libraries: glibc $(objdump -T "$OUT/bin/homeswift" "$OUT"/lib/* | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -n 1) at most"
