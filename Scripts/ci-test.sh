#!/bin/bash
# Runs Scripts/test.sh for CI with bounded parallelism, a watchdog and one retry of the tests that failed.
# The watchdog: when the tests write nothing for HANG_MINUTES (8 by default), to their output or the bundles' logs, it
# prints the stacks of the test processes (macOS `sample`, Linux `gdb` when installed) and fails, instead of waiting for
# the job's timeout. A hang then shows where it waits. A shorter silence (STALL_SECONDS, 20 by default) is noted when the
# output resumes: a runner that stops the process for a while makes the waits of the tests under way run out, and the
# note says so in the job's log.
# The retry: a run where a few tests failed (RETRY_MAX, 8 by default) runs those tests again, alone, in a fresh process
# (`--filter`, over the binaries just built). Tests that pass then are flaky, listed in a warning; a test that fails again,
# a run that failed without a test's failure (a build error, a crash, the watchdog) or many failures fail the job as
# before. It caps how many tests run at once (below). Arguments go to Scripts/test.sh.
set -uo pipefail

HANG_MINUTES="${HANG_MINUTES:-8}"
STALL_SECONDS="${STALL_SECONDS:-20}"
RETRY_MAX="${RETRY_MAX:-8}"
# macOS toolchains can produce separate bundles: bound both processes and tests
# per process. Linux has one test executable. Both allow at most eight tests by
# default, so small CI runners can service I/O before tests' deadlines expire.
if [ "$(uname)" = Darwin ]; then
    export HOMESWIFT_TEST_BUNDLES="${HOMESWIFT_TEST_BUNDLES:-2}"
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-4}"
else
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-8}"
fi
scripts="$(dirname "$0")"
watchdog_fired=false

# Runs Scripts/test.sh with the arguments after the log, its output to the terminal and to that log, under the watchdog.
run_tests() {
    local log="$1"
    shift
    TEST_LOG_DIR="$(mktemp -d -t swift-test-logs.XXXXXX)"
    export TEST_LOG_DIR
    # tee has a finite stream to drain. Killing a following tail after a fixed delay
    # could truncate a large failed bundle's output before its actual diagnostic.
    local stream
    stream="$(mktemp -d -t swift-test-stream.XXXXXX)"
    mkfifo "$stream/output"
    tee "$log" < "$stream/output" &
    local output=$!
    "$scripts/test.sh" "$@" > "$stream/output" 2>&1 &
    local tests=$!

    local last=-1 idle=0 size
    while kill -0 "$tests" 2>/dev/null; do
        # Notice completion promptly instead of adding up to 15 seconds to every run.
        # wc can count regular files without copying their entire contents through cat.
        sleep 1
        size=$(wc -c "$log" "$TEST_LOG_DIR"/* 2>/dev/null | tail -n 1)
        if [ "$size" = "$last" ]; then
            idle=$((idle + 1))
        else
            if [ "$idle" -ge "$STALL_SECONDS" ]; then
                echo "::notice::the tests printed nothing for ${idle}s and went on: the runner stalled, and the waits of the tests under way ran meanwhile"
            fi
            idle=0
            last=$size
        fi
        if [ "$idle" -ge $((HANG_MINUTES * 60)) ]; then
            echo "::error::the tests printed nothing for $HANG_MINUTES minutes: their stacks follow"
            local pid
            for pid in $(pgrep -f '[.]xctest'); do
                echo "=== process $pid: $(ps -o command= -p "$pid" | cut -c1-200)"
                if command -v sample > /dev/null; then
                    sample "$pid" 3 2>/dev/null | sed -n '/Call graph:/,/Total number in stack/p'
                elif command -v gdb > /dev/null; then
                    gdb -p "$pid" -batch -ex 'thread apply all bt' 2>/dev/null
                fi
            done
            local bundle_log
            for bundle_log in "$TEST_LOG_DIR"/*; do echo "=== the end of $(basename "$bundle_log")"; tail -n 20 "$bundle_log"; done
            kill "$tests" 2>/dev/null
            pkill -f '[.]xctest' 2>/dev/null
            watchdog_fired=true
            kill "$output" 2>/dev/null
            rm -rf "$stream"
            return 1
        fi
    done
    wait "$tests"
    local status=$?
    # A stall the tests ended right after.
    if [ "$idle" -ge "$STALL_SECONDS" ]; then
        echo "::notice::the tests printed nothing for ${idle}s before they ended: the runner stalled, and the waits of the tests under way ran meanwhile"
    fi
    wait "$output"
    local output_status=$?
    rm -rf "$stream"
    if [ "$status" -eq 0 ]; then status=$output_status; fi
    return $status
}

# The names of the tests a log reports failed (`✘ Test name() failed after …`), one per line, without their colours.
failed_tests() {
    sed -e 's/\x1b\[[0-9;]*m//g' "$1" | grep -a -oE '✘ Test [A-Za-z_][A-Za-z0-9_]*\(.* failed after ' | sed -E 's/^✘ Test ([A-Za-z_][A-Za-z0-9_]*)\(.*/\1/' | sort -u
}

LOG="$(mktemp -t swift-test.XXXXXX)"
run_tests "$LOG" "$@"
status=$?
if [ "$status" -eq 0 ] || "$watchdog_fired"; then exit $status; fi

failed=()
while IFS= read -r name; do [ -n "$name" ] && failed+=("$name"); done < <(failed_tests "$LOG")
if [ ${#failed[@]} -eq 0 ]; then
    echo "The tests failed without a test's failure (a build error or a crash): not run again"
    exit $status
fi
if [ ${#failed[@]} -gt "$RETRY_MAX" ]; then
    echo "${#failed[@]} tests failed, more than RETRY_MAX=$RETRY_MAX: not run again"
    exit $status
fi

# The failed tests alone, over the binaries just built: the arguments before `--` go to the build and the runner, those
# after it to the tests, where the filter goes.
before=()
after=()
seen=false
for argument in "$@"; do
    if ! "$seen" && [ "$argument" = -- ]; then seen=true; continue; fi
    if "$seen"; then after+=("$argument"); else before+=("$argument"); fi
done
filter="$(IFS='|'; echo "${failed[*]}")"
echo
echo "=== ${#failed[@]} tests failed: running them again, alone: ${failed[*]}"
RETRY_LOG="$(mktemp -t swift-test-retry.XXXXXX)"
run_tests "$RETRY_LOG" ${before[@]+"${before[@]}"} --skip-build -- ${after[@]+"${after[@]}"} --filter "$filter"
retry_status=$?
if "$watchdog_fired"; then exit 1; fi

# Every test must have run and passed this time: a filter that matched nothing would otherwise pass for it.
flaky=()
again=()
for name in "${failed[@]}"; do
    if sed -e 's/\x1b\[[0-9;]*m//g' "$RETRY_LOG" | grep -a -qE "✔ Test $name\(.* passed after "; then
        flaky+=("$name")
    else
        again+=("$name")
    fi
done
if [ "$retry_status" -eq 0 ] && [ ${#again[@]} -eq 0 ]; then
    echo "::warning::flaky tests, failed then passed alone: ${flaky[*]}"
    exit 0
fi
if [ ${#again[@]} -gt 0 ]; then echo "::error::tests failed again, or did not run: ${again[*]}"; fi
exit 1
