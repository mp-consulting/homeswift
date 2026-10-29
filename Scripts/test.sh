#!/bin/bash
# Builds the tests and runs them. On macOS `swift test` runs the test targets' bundles one after another; this runs
# them all at once (each bundle already runs its own tests in parallel), so the suite takes about as long as its
# slowest target rather than the sum of them. Elsewhere it runs `swift test`, whose tests are one executable already.
# Arguments go to `swift build`; those after `--` to the tests:
#   Scripts/test.sh --scratch-path ~/Library/Caches/homeswift-build -- --filter Govee
set -uo pipefail

build=()
tests=()
while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then
        shift
        tests=("$@")
        break
    fi
    build+=("$1")
    shift
done

swift build --build-tests ${build[@]+"${build[@]}"} || exit $?
if [ "$(uname)" != "Darwin" ]; then
    exec swift test --skip-build ${build[@]+"${build[@]}"} ${tests[@]+"${tests[@]}"}
fi

bin="$(swift build --show-bin-path ${build[@]+"${build[@]}"})"
developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
logs="$(mktemp -d -t homeswift-tests.XXXXXX)"
trap 'rm -rf "$logs"' EXIT

shopt -s nullglob
bundles=("$bin"/*.xctest)
if [ ${#bundles[@]} -eq 0 ]; then
    echo "No test bundles in $bin" >&2
    exit 1
fi

start=$SECONDS
names=()
pids=()
for bundle in "${bundles[@]}"; do
    name="$(basename "$bundle" .xctest)"
    binary="$bundle/Contents/MacOS/$name"
    # What `swift test` sets for a bundle: XCTest and Swift Testing from the developer directory.
    DYLD_FRAMEWORK_PATH="$developer/Library/Frameworks" DYLD_LIBRARY_PATH="$developer/usr/lib" \
        "$helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing ${tests[@]+"${tests[@]}"} \
        > "$logs/$name.log" 2>&1 &
    names+=("$name")
    pids+=("$!")
done

status=0
failed=()
for index in "${!pids[@]}"; do
    name="${names[$index]}"
    if wait "${pids[$index]}"; then
        summary="$(grep -a 'Test run with' "$logs/$name.log" | tail -n 1 | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[^T]*//')"
        printf '%-26s %s\n' "$name" "${summary:-no tests}"
    else
        status=1
        failed+=("$name")
    fi
done
# A failed bundle's whole output, after the summaries.
for name in ${failed[@]+"${failed[@]}"}; do
    echo
    echo "=== $name failed"
    cat "$logs/$name.log"
done
echo
echo "${#pids[@]} test bundles in $((SECONDS - start)) s${failed[@]+, ${#failed[@]} failed: ${failed[*]}}"
exit $status
