# Focused tests, timing fixtures, and flaky-test fixes

Measured on 2026-11-10 on the same 8-core Mac14,7 with 16 GiB RAM, macOS 27.2,
Swift 6.4.2, and the toolchain's default `swiftbuild` engine. The starting point
already includes batched asset generation, longest-first scheduling, and the
bounded test runner from [the preceding benchmark](batch-and-test-order.md).
[Raw measurements](focused-tests-results.json) retain every timed attempt and
validation result, including the initial failures.

| Workflow | Before median | After median | Observation |
|---|---:|---:|---|
| Govee tests, including build | 8.33 s | 5.38 s | 35% less time; one bundle instead of 55 |
| Govee tests, explicitly reusing binaries | 8.33 s | 2.24 s | 73% less time than the previous filtered command |
| Complete build-and-test command | 26.33 s | 25.31 s | Small change; the ranges overlap |
| Full-product shared-runtime rebuild, alternating commands | 5.94 s | 5.92 s | Effectively unchanged |

Each median has three samples. The full suite passed all three measured runs
on each side: 3,747 tests before and 3,748 after, across the same 55 bundles.
The additional test checks that a reset completing inside a write handler is
not overwritten when the write returns. No test cases were removed or disabled.
The full-suite difference is too small to claim a substantial speedup; focused
work and explicit build skipping provide the clear improvement in this round.

## What changed

- `bin/dev test Govee` or `GoveeTests` selects that known macOS test target.
  `--target GoveeTests` selects it explicitly and can accompany a narrower filter.
  Other filters continue to search all bundles. Targeted runs build only their
  target and dependencies and do not overwrite full-suite scheduling history.
- `--skip-build` deliberately runs existing binaries without compiling. It still
  queries SwiftPM for the configured binary directory. Missing selected bundles
  fail with a build instruction. Linux retains SwiftPM's test execution and
  supports skipping builds and filtering; explicit bundle selection is macOS-only.
- Account setup now finishes saving the first account's Home Language before
  returning. The previous background save could race an immediate config import,
  producing HTTP 409. The test checks both the running configuration and file
  immediately after setup, then imports without retrying.
- Reolink's momentary switches use `Characteristic.revert`, preserving a reset
  that completes before the write handler returns.
- Tado's debounce wait is injectable, with its production delay unchanged. The
  coalescing test holds the wait until all writes arrive. Initial-state checks
  wait for the relevant values and the actor's complete zone update.
- UniFi Access's fake controller now reports the same lock states and names as
  its streamed events, so polling does not undo the test's events.
- The invalid fingerprint fixture always contains the ASCII character it
  replaces, removing the random case in which the replacement changed nothing.

## Slow-test profile

The held-dimmer test used to wait 3.1 seconds for the writer's grace period.
Its fake applies writes immediately, so it now sets the existing `trustLastSet`
parameter to zero. The separate late-report test still covers that grace period.
Its median duration in the full-suite profiles fell from 5.63 to 1.75 seconds.
The negative observation window that checks a released hold stays stopped remains.

The HTTP parser test still checks 5,000 inputs in three buffer forms, using a
reproducible test-only random generator. Its measured duration was similar;
no separate speedup is claimed for that change. The camera claim stress test
still performs all 2,000 rounds of eight competing requests. It remains the
longest test, around 12 seconds under full-suite contention.

## Validation and measurement details

Before the UI fix, its full bundle failed twice in 20 repeated runs, with the
import response explicitly reporting HTTP 409. Afterward, all 20 full UI runs
passed. Another 45 repeated runs covered Reolink's chime, Tado's plugin suite,
UniFi Access's gate state, fingerprint rejection, and the dimmer/reset tests:
65 successful runs in total, with no retry-on-failure behavior in the runner.

The runner's Python regression checks cover ordering, history publication,
focused selection, missing/invalid targets, build skipping, and Linux argument
forwarding. A real source-edit check also rebuilt and ran Govee's 158 tests:
its binary was relinked while the unrelated HomeswiftTests binary retained its
mtime. The complete suite was run again after restoring that temporary edit.
Build logs contained no compiler warnings. Linux execution was checked with
mocked tools; the actual Linux Swift suite was not run on this Mac.

For full-suite measurements, the implementation/test sources were temporarily
restored to their starting versions, built once, and measured three times with
the captured starting runner. The revised sources were then restored, built
once, and measured three times. Preparation builds are retained in the JSON but
excluded from the medians. The final Tado actor-readiness assertion was added
after those timed runs and checked in its complete bundle, ten repetitions of
its plugin suite, and the final complete run. The initial profiling run failed
in UI import at 27.58 seconds and is retained separately.

The first shared-runtime check used a source timestamp change and measured
5.81 s before versus 6.09 s after. To distinguish that small difference from
run-to-run variation, the follow-up alternated the captured and current full
build commands, with a different comment-only edit to `PluginHost.swift` before
each build. Those medians were 5.94 s and 5.92 s. Both build scripts have the
same SHA-256; the package graph and shared-runtime module layout are unchanged.
This is a regression guard, not a claimed compiler optimization. The temporary
comments were restored and the restored source rebuilt.

## Commands

```sh
# Build and run one macOS target, or one test within it.
bin/dev test Govee
bin/dev test --target GoveeTests someTest

# Intentionally reuse the existing test binary; rebuild after source edits.
bin/dev test Govee --skip-build

# Full suite, and the full-product shared-runtime rebuild guard.
Scripts/test.sh --scratch-path ~/Library/Caches/homeswift-build
Scripts/build.sh --all --scratch-path ~/Library/Caches/homeswift-build

# Runner regression checks without a Swift build.
python3 Scripts/test-test-runner.py
```
