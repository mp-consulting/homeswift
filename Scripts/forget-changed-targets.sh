#!/bin/sh
# Drops, from a build restored from CI's cache, what was built of the targets a pull request changes: their objects and
# modules are compiled whole instead. Scripts/restore-mtimes.swift dates files by their last commit, which can be older
# than the base's cached build: the macOS runner kept a stale object of a file the branch changed (HAPServer.swift) and
# failed to link, even with that file dated now.
# Run after the cache is restored, with the key it came from as $CACHE_KEY: main's keys end with the commit they were
# built from, which is what the checkout is compared with, so a pull request on another pull request's branch rebuilds
# both branches' changes. Without such a commit, a pull request's merge commit is compared with its base; anything else
# does nothing.
set -e
built=${CACHE_KEY##*-}
if printf '%s' "$built" | grep -qE '^[0-9a-f]{40}$' && git cat-file -e "$built^{commit}" 2>/dev/null; then
  base=$built
elif git rev-parse --verify --quiet HEAD^2 >/dev/null; then
  base=HEAD^1
else
  exit 0
fi
targets=$(git diff --name-only --no-renames "$base" HEAD | sed -nE \
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
  if [ -d "$folder" ]; then find "$folder" \( "$@" \) -prune -exec rm -rf {} +; fi
done
echo "Rebuilding" $targets
