#!/bin/sh
# Drops, from a build restored from CI's cache, what was built of the targets a pull request changes: their objects and
# modules are compiled whole instead. Scripts/restore-mtimes.swift dates files by their last commit, which can be older
# than the base's cached build: the macOS runner kept a stale object of a file the branch changed (HAPServer.swift) and
# failed to link, even with that file dated now.
# Run on a merge commit (a pull request's), after the cache is restored; elsewhere it does nothing.
# The cache a pull request can restore is main's: what changed is counted from where its branch leaves main, not from its
# base, so a pull request stacked on another branch rebuilds that branch's changes too (#22 kept main's HomeswiftAI and
# missed #21's prompts).
set -e
git rev-parse --verify --quiet HEAD^2 >/dev/null || exit 0
base=HEAD^1
if git rev-parse --verify --quiet origin/main >/dev/null; then base=$(git merge-base HEAD origin/main); fi
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
