#!/bin/bash
# Builds with the toolchain's default engine. Runs macOS test bundles through a
# bounded worker pool; elsewhere SwiftPM runs the tests in one executable.
# Arguments go to `swift build`; those after `--` to the tests:
# --target GoveeTests builds/runs just that macOS bundle; --skip-build uses existing binaries.
#   Scripts/test.sh --scratch-path ~/Library/Caches/homeswift-build -- --filter Govee
set -uo pipefail

build=()
tests=()
skip_build=false
target=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then
        shift
        tests=("$@")
        break
    fi
    case "$1" in
        --skip-build) skip_build=true; shift; continue ;;
        --target)
            if [ -z "${2:-}" ]; then echo "--target needs a test target" >&2; exit 2; fi
            target="$2"; shift 2; continue ;;
        --target=) echo "--target needs a test target" >&2; exit 2 ;;
        --target=*) target="${1#*=}"; shift; continue ;;
    esac
    build+=("$1")
    shift
done

scripts="$(cd "$(dirname "$0")" && pwd)"
platform="$(uname)"
if [ -n "$target" ] && ! [[ "$target" =~ ^[A-Za-z_][A-Za-z0-9_]*Tests$ ]]; then
    echo "--target must name a test target, for example GoveeTests" >&2; exit 2
fi
if [ -n "$target" ] && [ "$platform" != Darwin ]; then
    echo "--target requires macOS test bundles; use -- --filter on Linux" >&2; exit 2
fi
if ! "$skip_build"; then
    if [ -n "$target" ]; then
        "$scripts/build.sh" --target "$target" ${build[@]+"${build[@]}"} || exit $?
    else
        "$scripts/build.sh" --build-tests ${build[@]+"${build[@]}"} || exit $?
    fi
fi
# Bound both levels of parallelism: the old runner launched all 55 bundles and
# their tests together, causing CPU contention and intermittent timeouts.
test_width=8
if [ "$platform" = Darwin ]; then test_width=4; fi
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$test_width}"
if [ "$platform" != "Darwin" ]; then
    exec swift test --skip-build ${build[@]+"${build[@]}"} ${tests[@]+"${tests[@]}"}
fi

# A cached location saves a second SwiftPM planning invocation. The build above
# always runs unless --skip-build was explicitly requested. Unknown options and
# missing/corrupt entries fall back to querying the toolchain.
if ! bin="$(python3 "$scripts/test-bin-cache.py" read ${build[@]+"${build[@]}"} 2>/dev/null)"; then
    bin="$("$scripts/build.sh" --show-bin-path ${build[@]+"${build[@]}"})" || exit $?
    python3 "$scripts/test-bin-cache.py" write "$bin" ${build[@]+"${build[@]}"} 2>/dev/null || true
fi
developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
# $TEST_LOG_DIR keeps the bundles' logs where Scripts/ci-test.sh's watchdog sees them grow; otherwise a temporary folder.
if [ -n "${TEST_LOG_DIR:-}" ]; then
    logs="$TEST_LOG_DIR"
    mkdir -p "$logs"
else
    logs="$(mktemp -d -t homeswift-tests.XXXXXX)"
    trap 'rm -rf "$logs"' EXIT
fi

shopt -s nullglob
if [ -n "$target" ]; then
    if [ ! -f "$bin/$target.xctest/Contents/MacOS/$target" ]; then
        echo "Missing test bundle $target; run without --skip-build to build it" >&2; exit 1
    fi
    bundles=("$bin/$target.xctest")
else
    bundles=("$bin"/*.xctest)
fi
if [ ${#bundles[@]} -eq 0 ]; then
    echo "No test bundles in $bin" >&2
    exit 1
fi

# Start long-running bundles first so they do not become the tail of the pool.
# Seed estimates work on the first run; subsequent full runs learn this machine.
history="$bin/.homeswift-test-durations.tsv"
previous=/dev/null
if [ -f "$history" ]; then previous="$history"; fi
expected_bundles=${#bundles[@]}
printf '%s\n' "${bundles[@]}" > "$logs/bundles.list" || exit 1
awk -f "$scripts/test-order.awk" "$scripts/test-durations.tsv" "$previous" "$logs/bundles.list" \
    | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 > "$logs/bundles.ordered" || exit 1
bundles=()
while IFS=$'\t' read -r duration bundle; do
    bundles+=("$bundle")
done < "$logs/bundles.ordered"
if [ ${#bundles[@]} -ne "$expected_bundles" ]; then
    echo "Test ordering did not preserve the bundle count" >&2
    exit 1
fi

start=$SECONDS
names=()
pids=()
codes=()
active=()
running=0
bundle_jobs="${HOMESWIFT_TEST_BUNDLES:-16}"
if ! [[ "$bundle_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "HOMESWIFT_TEST_BUNDLES must be a positive integer" >&2
    exit 2
fi

# Bash 3.2 on macOS has no wait -n. Reap whichever workers have finished instead
# of waiting for a whole batch (or for the first, possibly slowest, worker).
reap() {
    local index
    for index in ${active[@]+"${!active[@]}"}; do
        if ! kill -0 "${pids[$index]}" 2>/dev/null; then
            wait "${pids[$index]}"
            codes[$index]=$?
            unset 'active[index]'
            running=$((running - 1))
        fi
    done
}
for bundle in "${bundles[@]}"; do
    while [ "$running" -ge "$bundle_jobs" ]; do
        reap
        if [ "$running" -ge "$bundle_jobs" ]; then sleep 0.05; fi
    done
    name="$(basename "$bundle" .xctest)"
    binary="$bundle/Contents/MacOS/$name"
    # What `swift test` sets for a bundle: XCTest and Swift Testing from the developer directory.
    DYLD_FRAMEWORK_PATH="$developer/Library/Frameworks" DYLD_LIBRARY_PATH="$developer/usr/lib" \
        "$helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing ${tests[@]+"${tests[@]}"} \
        > "$logs/$name.log" 2>&1 &
    names+=("$name")
    pids+=("$!")
    active[$((${#pids[@]} - 1))]=1
    running=$((running + 1))
done
while [ "$running" -gt 0 ]; do
    reap
    if [ "$running" -gt 0 ]; then sleep 0.05; fi
done

status=0
failed=()
: > "$logs/durations.tsv"
for index in "${!pids[@]}"; do
    name="${names[$index]}"
    code=${codes[$index]}
    if [ "$code" -eq 0 ]; then
        summary="$(grep -a 'Test run with' "$logs/$name.log" | tail -n 1 | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[^T]*//')"
        printf '%-26s %s\n' "$name" "${summary:-no tests}"
        duration="$(printf '%s\n' "$summary" | sed -nE 's/.* after ([0-9]+([.][0-9]+)?) seconds\..*/\1/p')"
        if [ -n "$duration" ]; then printf '%s\t%s\n' "$duration" "$name" >> "$logs/durations.tsv"; fi
    elif [ "$code" -eq 69 ] && [ ${#tests[@]} -gt 0 ]; then
        # Swift Testing's EX_UNAVAILABLE: a filter matched none of the bundle's tests.
        printf '%-26s %s\n' "$name" "no matching tests"
    else
        status=1
        failed+=("$name")
    fi
done
# Filters and failing runs are not representative of complete bundle duration.
# Publish atomically so another runner cannot read a partially written history.
if [ "$status" -eq 0 ] && [ ${#tests[@]} -eq 0 ] && [ -z "$target" ] && [ -s "$logs/durations.tsv" ]; then
    if history_tmp="$(mktemp "$history.XXXXXX")"; then
        if ! cp "$logs/durations.tsv" "$history_tmp" || ! mv -f "$history_tmp" "$history"; then
            rm -f "$history_tmp"
        fi
    fi
fi
# A failed bundle's whole output, after the summaries.
for name in ${failed[@]+"${failed[@]}"}; do
    echo
    echo "=== $name failed"
    cat "$logs/$name.log"
done
echo
echo "${#pids[@]} test bundles in $((SECONDS - start)) s${failed[@]+, ${#failed[@]} failed: ${failed[*]}}"
exit $status
