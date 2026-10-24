#!/bin/sh
# Builds the Synology packages (docs/synology.md): an .spk per architecture in .build/synology/.
#
#   Synology/build.sh                  x86_64 and aarch64, the binaries built in Docker (Synology/Dockerfile)
#   Synology/build.sh aarch64          one architecture
#   BINARIES=dir Synology/build.sh     binaries built already, in dir/<arch>/bin (homeswift, ffmpeg) and dir/<arch>/lib
#
# An .spk is a tar of INFO, package.tgz (what lands in /var/packages/homeswift/target), the scripts, the
# DSM configuration, the wizard and the icons. No Synology toolchain is needed: the binary comes from
# Amazon Linux 2, whose glibc is DSM 7.0's. INFO names no admin port or protocol: it is fixed at install, while
# the web UI's port and HTTPS live in config.json. Package Center opens the main menu's entry (dsmappname),
# which start.sh keeps on them.
set -eu

cd "$(dirname "$0")/.."
VERSION=${VERSION:-$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/HomeswiftPlugin/PluginHost.swift)}
# DSM versions are <version>-<build>; a new build of the same release must be higher to upgrade.
BUILD=${BUILD:-1}
OUT=${OUT:-.build/synology}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# Owner root and no macOS metadata in the archives, with either tar.
if tar --version 2>/dev/null | grep -q GNU; then
    TAR_OPTIONS="--format=ustar --owner=0 --group=0 --numeric-owner"
else
    TAR_OPTIONS="--format=ustar --uid 0 --gid 0 --no-xattrs --no-mac-metadata"
    export COPYFILE_DISABLE=1
fi

for arch in ${*:-x86_64 aarch64}; do
    case $arch in
        x86_64)
            platform=linux/amd64
            dsm_arch="x86_64"
            ;;
        aarch64)
            platform=linux/arm64
            # The 64-bit ARM platforms by name too: DS220j, DS223, DS120j and the others (Package Center
            # matches the model's platform or its family).
            dsm_arch="aarch64 armv8 rtd1296 rtd1619b armada37xx"
            ;;
        *)
            echo "build.sh: unknown architecture $arch (x86_64 or aarch64)" >&2
            exit 1
            ;;
    esac

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    mkdir -p "$work/package" "$work/spk"
    if [ -n "${BINARIES:-}" ]; then
        cp -R "$BINARIES/$arch/bin" "$BINARIES/$arch/lib" "$work/package/"
    else
        docker buildx build --platform "$platform" -f Synology/Dockerfile --output "type=local,dest=$work/package" .
    fi
    cp -R Synology/package/. "$work/package/"
    find "$work" -name .DS_Store -delete
    chmod 755 "$work/package/bin/"* "$work/package/app/homeswift" "$work/package/app/"*.sh

    # shellcheck disable=SC2086
    tar $TAR_OPTIONS -czf "$work/spk/package.tgz" -C "$work/package" .
    cp -R Synology/conf Synology/scripts Synology/WIZARD_UIFILES Synology/PACKAGE_ICON.PNG Synology/PACKAGE_ICON_256.PNG "$work/spk/"
    chmod 755 "$work/spk/scripts/"*

    cat > "$work/spk/INFO" <<EOF
package="homeswift"
version="$VERSION-$BUILD"
os_min_ver="7.0-40000"
arch="$dsm_arch"
displayname="Homeswift"
description="A HomeKit bridge with plugins, a web UI and an MCP server: Homebridge in Swift. HomeKit finds it over Bonjour; the web UI is on port 8581."
maintainer="mp-consulting"
maintainer_url="https://github.com/mp-consulting/homeswift"
support_url="https://github.com/mp-consulting/homeswift/issues"
helpurl="https://github.com/mp-consulting/homeswift/blob/main/docs/synology.md"
thirdparty="yes"
startable="yes"
ctl_stop="yes"
silent_install="no"
silent_upgrade="yes"
dsmuidir="ui"
dsmappname="homeswift.homeswift"
checkport="no"
extractsize="$(du -sk "$work/package" | cut -f1)"
checksum="$( (md5sum "$work/spk/package.tgz" 2>/dev/null || md5 -r "$work/spk/package.tgz") | cut -d' ' -f1)"
create_time="$(date -u +%Y%m%d-%H:%M:%S)"
EOF

    spk="$OUT/homeswift-$arch-$VERSION-$BUILD.spk"
    # shellcheck disable=SC2086
    tar $TAR_OPTIONS -cf "$spk" -C "$work/spk" INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
    rm -rf "$work"
    trap - EXIT
    echo "$spk"
done
