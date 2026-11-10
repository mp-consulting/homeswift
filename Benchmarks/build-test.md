# Default engine build and test timings

See the [batch-generation and slowest-first follow-up](batch-and-test-order.md) for the next round of measurements.

Measured on 10 November 2026 on a Mac14,7, 8 CPUs, 16 GiB RAM, macOS 27.2,
Apple Swift 6.4.2. Baseline: `18fc6757a75330b54e9b519d4938796d3808477a`.
All retained changes use the toolchain's **default engine (Swift Build)**.
[Raw timings, commands, warning counts and failures](build-test-results.json).

| Workflow | Before | After | Result |
|---|---:|---:|---|
| `bin/dev test` | 99.99 s | 25.49 s | 75% less time; same 3,747 tests |
| Shared-runtime edit, **all products** | 7.92 s | 7.61 s | No observed regression in the interleaved comparison |
| Shared-runtime edit, everyday **bridge build** | 7.92 s | 5.62 s | 29% less time by narrowing product output |
| CI completion-wrapper overhead | 16.05 s | 2.06 s | Instant stub; not an end-to-end CI measurement |

The full-product row compares the original `bin/dev build` with the new
`bin/dev build --all`. The bridge-only row builds `homeswift` and all its plugin
and library dependencies, but omits the demo and standalone library product
archives. This scope difference is intentional and is not a compiler speedup.
CI retains its original full release-build command, `swift build -c release`.

## Changes

- `bin/dev build` and `Scripts/build.sh` select the bridge product by default.
  `--all`, explicit `--product`/`--target`, and `--build-tests` preserve full or
  explicitly selected builds. `bin/dev build --all` follows its original direct
  SwiftPM path.
- `bin/dev test` uses the parallel test runner instead of plain `swift test`'s
  sequential macOS bundle execution. `bin/dev check` embeds files and builds
  tests once, removing its redundant build-before-`swift test` step.
- The runner admits eight bundles with at most eight tests each locally. CI uses
  two bundles with four tests each on macOS, or eight tests in Linux's single
  executable. Both levels can be configured with `HOMESWIFT_TEST_BUNDLES` and
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`.
- Asset, schema, prompt and Govee scene generation preserves unchanged bytes,
  inodes and modification times. Changed inputs still regenerate their output.
- The CI watchdog polls completion every second rather than every 15 seconds.

There are no retained changes to `Package.swift`, application sources or test
assertions. Asset-module isolation was measured and rejected because it slowed
shared-runtime rebuilds. The deprecated-engine selection was removed completely.
Final measured builds emitted **zero warnings**, without warning-suppression flags.

## Measurement details

The standard test baseline is one successful 99.988-second `swift test` run from
the same checkout and machine. The final runner passed three complete suites:
36.589, 25.659 and 25.327 seconds. The first included build-plan preparation; the
table uses the mean of the two warm runs. Each executed all 3,747 tests across 55
bundles. The old parallel `Scripts/test.sh` was already faster than plain
`swift test`; the large test improvement applies to the actual `bin/dev test`
entry point. The earlier unrestricted runner also produced an intermittent
server-test failure in this session, retained in the raw data.

Full-product shared-runtime rebuilds were measured in three interleaved pairs,
reversing command order in pair two. Original `bin/dev build`: 9.912, 7.797,
7.915 seconds. New `bin/dev build --all`: 7.609, 7.457, 7.761 seconds. The table
uses medians. These small differences are within ordinary run-to-run variation;
the full build has the same product graph and compiler arguments.

Bridge-only rebuilds took 11.026, 5.611 and 5.622 seconds; their median is shown.
Each edit prepended a different number of comment lines to
`Sources/HomeswiftPlugin/Slug.swift`, changing debug line information and forcing
compilation and relinking. The original bytes were restored after every group.
The raw data also retains preliminary runs, including full-build measurements
that varied with build-plan cache transitions and shell entry points. It does
not discard slower samples or failed tests.

Builds were run sequentially against the external scratch directory
`~/Library/Caches/homeswift-build`. No cold-build, release-build or Linux speedup
is claimed. Initial cache preparation is excluded from warm comparisons.

## Use and reproduce

```sh
# Fast everyday commands, using the existing external build cache.
bin/dev build
bin/dev test
bin/dev test Govee
bin/dev check

# Preserve the original full product build.
bin/dev build --all

# Explicit product/target selection remains available.
Scripts/build.sh --scratch-path ~/Library/Caches/homeswift-build --product homeswift-demo

# Compare test entry points after warming the cache.
/usr/bin/time -p swift test --scratch-path ~/Library/Caches/homeswift-build
/usr/bin/time -p bin/dev test
```

Repeat timings with no competing builds. For shared-runtime measurements, make
and restore a comment-only edit before each build; do not compare a rebuild with
an unchanged invocation. Keep product scope explicit. The raw JSON records the
exact commands and identifies discarded experiments.

Validation: three complete successful suites; generator idempotence and changed
input checks for all three embed modes; unchanged Govee generation; six build
argument-forwarding cases; shell syntax and whitespace checks. The watchdog's
success, nonzero-exit forwarding and timeout behavior were checked with isolated
stubs. Linux execution remains for CI.
