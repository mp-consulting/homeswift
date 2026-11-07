#!/bin/sh
# Drops, from a build restored from CI's cache, what was built of the targets changed since that build: their objects
# and modules are compiled whole instead. Scripts/restore-mtimes.swift dates files by their last commit, which can be
# older than the cached build: the macOS runner kept a stale object of a file that changed (HAPServer.swift) and failed
# to link, even with that file dated now.
# The commit a build was made from is in .build/.built-from (written before each save). It is what the checkout is
# compared with, a pull request's own cache included: after the branch merges main, main's changes are newer than the
# pull request's first build, and their files' commit dates are older. A cache saved before .built-from existed falls
# back to its key (main's keys end with their commit), then to a pull request's merge commit against its base.
set -e
built=$(cat .build/.built-from 2>/dev/null || true)
[ -n "$built" ] || built=${CACHE_KEY##*-}
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
