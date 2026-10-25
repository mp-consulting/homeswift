#!/bin/bash
# Runs `swift test` for CI with a watchdog: when the tests print nothing for HANG_MINUTES (8 by default), it prints the
# stacks of the test process (macOS `sample`, Linux `gdb` when installed) and fails, instead of waiting for the job's
# timeout. A hang then shows where it waits. Arguments go to `swift test`.
set -uo pipefail

HANG_MINUTES="${HANG_MINUTES:-8}"
LOG="$(mktemp -t swift-test.XXXXXX)"

swift test "$@" > "$LOG" 2>&1 &
TESTS=$!
tail -n +1 -f "$LOG" &
TAIL=$!

last=-1
idle=0
while kill -0 "$TESTS" 2>/dev/null; do
    sleep 15
    size=$(wc -c < "$LOG")
    if [ "$size" = "$last" ]; then idle=$((idle + 15)); else idle=0; last=$size; fi
    if [ "$idle" -ge $((HANG_MINUTES * 60)) ]; then
        echo "::error::the tests printed nothing for $HANG_MINUTES minutes: their stacks follow"
        for pid in $(pgrep -f 'PackageTests[.]xctest'); do
            echo "=== process $pid: $(ps -o command= -p "$pid" | cut -c1-200)"
            if command -v sample > /dev/null; then
                sample "$pid" 3 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p'
            elif command -v gdb > /dev/null; then
                gdb -p "$pid" -batch -ex 'thread apply all bt' 2>/dev/null
            fi
        done
        kill "$TESTS" 2>/dev/null
        pkill -f 'PackageTests[.]xctest' 2>/dev/null
        kill "$TAIL" 2>/dev/null
        exit 1
    fi
done
wait "$TESTS"
status=$?
sleep 1
kill "$TAIL" 2>/dev/null
exit $status
