# Further clean-build tuning: no change retained

Measured on 2026-11-10, Swift 6.4.2, macOS 27.2, Mac14,7 (8 cores,
16 GiB RAM), debug configuration, default **swiftbuild** engine.
The baseline is the existing two-batch wrapper from the
[previous benchmark](clean-build-batching.md), including all prior authorized
working-tree optimizations—not git HEAD.
[Raw measurements](clean-build-followup-results.json).

## Clean all-product builds

Wall-clock seconds, including planning, compilation and linking:

| Pair | Current: two batches | Candidate: one batch | Candidate result |
|---|---:|---:|---|
| 1 | 137.25 | 134.21 | 2.2% faster |
| 2 | 128.85 | 110.09 | 14.6% faster |
| 3 | 114.50 | 132.44 | 15.7% slower |
| Median | **128.85** | **132.44** | **2.8% slower** |

One batch did not produce a repeatable wall-clock improvement. Its median
child-process CPU time was slightly lower (751.53 → 735.20 seconds, user plus
system), but that did not translate into a faster median build. Machine/load
variation and the compiler's scheduling critical path matter; the fastest
candidate run alone would have given a misleading result. **Rejected.**

A separate screening build kept two batches and raised scheduler concurrency
from the default 8 jobs to 12. It took **143.60 seconds**, versus the initial
137.25-second baseline, and consumed 812.77 child-process CPU seconds versus
780.22. This single screening result supplied no evidence to justify raising
concurrency; it was not promoted to a repeated candidate. **Rejected.**

## Shared-runtime guard

Each series appended three distinct comments to
`Sources/HomeswiftPlugin/PluginHost.swift`, rebuilding all products after each
edit. The original source bytes were restored in a `finally` block.

| Setting | Samples (seconds) | Median |
|---|---|---:|
| Current two batches | 9.854, 6.086, 6.504 | 6.504 |
| One batch, first series | 6.743, 6.294, 6.375 | 6.375 |
| One batch, repeated series | 6.621, 6.286, 6.484 | 6.484 |

The one-batch setting showed no measured steady-state shared-runtime regression,
but failed the clean-build improvement gate. The 12-job setting was rejected
at the clean-build screening stage, so it did not need a rebuild guard.
The existing two-batch default remains unchanged.

## Method and validation

All seven clean full-product builds passed with no compiler warnings. Runs were
sequential in a task-owned scratch directory outside the checkout. Before each
clean run, `out`, `manifest.pif` and `debug` were removed; dependency checkouts,
repositories, artifacts and workspace state were retained. No network resolution
was needed. OS and toolchain caches were not flushed, and the host was not
isolated from ordinary background activity. CPU measurements use Python's
`resource.getrusage(RUSAGE_CHILDREN)`; they are not machine-wide CPU totals.

The commands were:

```sh
HOMESWIFT_BUILD_BATCHES=2 Scripts/build.sh --all --scratch-path /tmp/homeswift-clean-next/scratch --disable-automatic-resolution
HOMESWIFT_BUILD_BATCHES=1 Scripts/build.sh --all --scratch-path /tmp/homeswift-clean-next/scratch --disable-automatic-resolution
HOMESWIFT_BUILD_BATCHES=2 Scripts/build.sh --all --scratch-path /tmp/homeswift-clean-next/scratch --disable-automatic-resolution --jobs 12
```

Execution order was baseline 1, its rebuild guard, one-batch 1, its guard,
12-job screening, then baseline 2/one-batch 2 and baseline 3/one-batch 3,
followed by the repeated one-batch guard. The report preserves every result.

**No implementation change was retained.** The default engine, product set,
debug information, test files, test selection, package graph and build wrapper
are unchanged. Consequently, this follow-up did not rerun the full test suite:
there is no retained compiler/code change requiring a new full-suite check.
The retained two-batch setting's previous validation was two successful runs of
3,748 tests across 55 bundles, recorded in the linked report; those are not new
runs from this follow-up. Full coverage has not been reduced.

`git diff --check` passed, and the temporary runtime edit was fully restored.
The task-owned scratch build was removed after measurement to reclaim disk
space; the regular build cache was only read to copy dependency checkouts.
