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
[ -d .build ] || exit 0
for target in $targets; do
  find .build \( -name "$target.build" -o -name "$target.swiftmodule" -o -name "$target.swiftdoc" \) -prune -exec rm -rf {} +
  echo "Rebuilding $target"
done
