#!/bin/sh
# Gathers the licences a binary of homeswift goes out with (the container image, the Synology package):
# Homeswift's own, the notices of the projects it ports, and the licence and notice files of every package
# compiled in, from SwiftPM's checkouts. Run from the repository root (or the build's copy of it):
#
#   Scripts/collect-licenses.sh <checkouts directory> <out directory>
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <checkouts directory> <out directory>" >&2; exit 2; }
checkouts=$1
out=$2

mkdir -p "$out/packages"
cp LICENSE THIRD-PARTY-NOTICES.md "$out/"
cp -R LICENSES "$out/"
for package in "$checkouts"/*/; do
    name=$(basename "$package")
    files=$(find "$package" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'COPYING*' \))
    if [ -z "$files" ]; then
        echo "collect-licenses: $name has no licence file; add its licence to THIRD-PARTY-NOTICES.md and here" >&2
        exit 1
    fi
    mkdir -p "$out/packages/$name"
    for file in $files; do cp "$file" "$out/packages/$name/"; done
done
echo "collect-licenses: $(cd "$out/packages" && echo *)"
