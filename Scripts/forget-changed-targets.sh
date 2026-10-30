#!/bin/sh
# Drops, from a build restored from CI's cache, what was built of the targets a pull request changes: their objects and
# modules are compiled whole instead. Scripts/restore-mtimes.swift dates a pull request's files now, yet the macOS
# runner's incremental build kept a stale object of a file the branch changed (HAPServer.swift) and failed to link.
# Run on a merge commit (a pull request's), after the cache is restored; elsewhere it does nothing.
set -e
git rev-parse --verify --quiet HEAD^2 >/dev/null || exit 0
targets=$(git diff --name-only --no-renames HEAD^1 HEAD | sed -nE \
  -e 's#^Sources/([^/]+)/.*#\1#p' \
  -e 's#^Tests/([^/]+)/.*#\1#p' \
  -e 's#^Plugins/([^/]+)/Sources/.*#Homeswift\1#p' \
  -e 's#^Plugins/([^/]+)/Tests/.*#\1Tests#p' | sort -u)
[ -n "$targets" ] || exit 0
# Only the build products (a triple's debug and release folders), never the dependencies' checkouts; one walk for all.
set --
for target in $targets; do set -- "$@" -o -name "$target.build" -o -name "$target.swiftmodule" -o -name "$target.swiftdoc"; done
shift
for folder in .build/*/debug .build/*/release; do
  [ -d "$folder" ] && find "$folder" \( "$@" \) -prune -exec rm -rf {} +
done
echo "Rebuilding" $targets
