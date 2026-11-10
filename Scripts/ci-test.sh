#!/bin/bash
# Runs Scripts/test.sh for CI with bounded parallelism and a watchdog: when the tests
# write nothing for HANG_MINUTES (8 by default), to their output or the bundles' logs, it prints the stacks of the test
# processes (macOS `sample`, Linux `gdb` when installed) and fails, instead of waiting for the job's timeout. A hang
# then shows where it waits. It caps how many tests run at once (below). Arguments go to Scripts/test.sh.
set -uo pipefail

HANG_MINUTES="${HANG_MINUTES:-8}"
# The default macOS engine has separate bundles: bound both processes and tests
# per process. Linux has one test executable. Both allow at most eight tests by
# default, so small CI runners can service I/O before tests' deadlines expire.
if [ "$(uname)" = Darwin ]; then
    export HOMESWIFT_TEST_BUNDLES="${HOMESWIFT_TEST_BUNDLES:-2}"
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-4}"
else
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-8}"
fi
LOG="$(mktemp -t swift-test.XXXXXX)"
export TEST_LOG_DIR="$(mktemp -d -t swift-test-logs.XXXXXX)"

# tee has a finite stream to drain. Killing a following tail after a fixed delay
# could truncate a large failed bundle's output before its actual diagnostic.
STREAM="$(mktemp -d -t swift-test-stream.XXXXXX)"
mkfifo "$STREAM/output"
tee "$LOG" < "$STREAM/output" &
OUTPUT=$!
trap 'kill "$OUTPUT" 2>/dev/null || true; rm -rf "$STREAM"' EXIT
"$(dirname "$0")/test.sh" "$@" > "$STREAM/output" 2>&1 &
TESTS=$!

last=-1
idle=0
while kill -0 "$TESTS" 2>/dev/null; do
    # Notice completion promptly instead of adding up to 15 seconds to every run.
    # wc can count regular files without copying their entire contents through cat.
    sleep 1
    size=$(wc -c "$LOG" "$TEST_LOG_DIR"/* 2>/dev/null | tail -n 1)
    if [ "$size" = "$last" ]; then idle=$((idle + 1)); else idle=0; last=$size; fi
    if [ "$idle" -ge $((HANG_MINUTES * 60)) ]; then
        echo "::error::the tests printed nothing for $HANG_MINUTES minutes: their stacks follow"
        for pid in $(pgrep -f '[.]xctest'); do
            echo "=== process $pid: $(ps -o command= -p "$pid" | cut -c1-200)"
            if command -v sample > /dev/null; then
                sample "$pid" 3 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p'
            elif command -v gdb > /dev/null; then
                gdb -p "$pid" -batch -ex 'thread apply all bt' 2>/dev/null
            fi
        done
        for log in "$TEST_LOG_DIR"/*; do echo "=== the end of $(basename "$log")"; tail -n 20 "$log"; done
        kill "$TESTS" 2>/dev/null
        pkill -f '[.]xctest' 2>/dev/null
        exit 1
    fi
done
wait "$TESTS"
status=$?
wait "$OUTPUT"
output_status=$?
if [ "$status" -eq 0 ]; then status=$output_status; fi
exit $status
