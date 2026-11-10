# Clean full-build compiler batching

Measured on 2026-11-10 with Swift 6.4.2, macOS 27.2, Mac14,7 (8 cores,
16 GiB RAM), debug configuration and the **default swiftbuild engine**.
The baseline includes the previous build/test optimizations in the working tree;
it is not git HEAD. [Raw measurements](clean-build-batching-results.json).

## Retained change

`Scripts/build.sh` uses `-Xswiftc -driver-batch-count -Xswiftc 2` for macOS
debug builds. This also applies to `Scripts/test.sh` and the `bin/dev` commands
that call the wrapper. The compiler parses/type-checks fewer separate batches
of each target's sources. All products, source files, debug information and tests
remain included; no optimization level or engine change is involved.

Release and Linux builds retain their previous settings. Explicit compiler
batching flags take precedence. `HOMESWIFT_BUILD_BATCHES=0` restores automatic
batching, and a positive integer selects a different count. Direct `swift build`
commands retain SwiftPM's defaults. There are no unsafe flags in Package.swift.
Changing compiler flags invalidates an existing debug cache once; the rebuild
guard below measures steady-state edits after preparing each configuration.

## Clean all-product results

Wall-clock seconds, including the build command's planning and linking:

| Pair | Automatic batches | Two batches | Reduction |
|---|---:|---:|---:|
| 1 | 147.02 | 124.97 | 15.0% |
| 2 | 120.30 | 115.49 | 4.0% |
| 3 | 123.13 | 113.66 | 7.7% |
| Median | **123.13** | **115.49** | **6.2%** |

All six builds passed. Background CPU activity varied, and the first pair was
slower overall. Every pair favored two batches; report the three-run medians,
not the first pair's larger improvement. These measurements characterize this
machine/toolchain, not every core count or Swift version.

The third pair also recorded child-process CPU time with Python's
`resource.getrusage(RUSAGE_CHILDREN)`: user plus system time decreased from
800.47 to 730.34 seconds (8.8%). This is supporting evidence of less compiler
work, not a substitute for wall-clock measurement or a machine-wide CPU profile.

Each clean run deleted the task-owned scratch directory's `out`, `manifest.pif`
and `debug` outputs, retaining dependency checkouts, repositories, artifacts and
workspace state. No network resolution was needed. System/toolchain caches and
the OS filesystem cache were not flushed. Runs were sequential, without another
benchmark or test build running beside them. These runs did **not** enable the
compiler-statistics instrumentation used in the earlier profile, so do not
compare their absolute times with that report's 174.85-second instrumented run.

Commands, with an isolated scratch directory outside the checkout:

```sh
# Before: same wrapper, with automatic batching.
HOMESWIFT_BUILD_BATCHES=0 Scripts/build.sh --all --scratch-path /tmp/homeswift-clean-build --disable-automatic-resolution

# After: the new macOS debug default.
Scripts/build.sh --all --scratch-path /tmp/homeswift-clean-build --disable-automatic-resolution
```

The recorded trials used the original wrapper with the explicit compiler flags
for the candidate, before installing the equivalent wrapper default. Full-suite
and final shared-runtime validation use the installed wrapper itself.

## Shared-runtime rebuild guard

The guard appends a distinct comment to `Sources/HomeswiftPlugin/PluginHost.swift`
and rebuilds **all products**, three times per configuration. It restores the
original bytes in a `finally` block. Source dependency boundaries are unchanged.

| Configuration | Samples (seconds) | Median |
|---|---|---:|
| Automatic batches | 8.960, 6.137, 6.036 | 6.137 |
| Explicit two-batch candidate | 9.257, 6.111, 6.088 | 6.111 |
| Final wrapper, after full-suite validation | 8.414, 5.392, 5.351 | 5.392 |

These results show no measured steady-state regression; the medians are
effectively equal. They do not establish a shared-runtime compilation speedup.

## Rejected asset experiments

Two alternatives isolated the UI's 17 MB of generated data from the server:

| Experiment | Clean build | Decision |
|---|---:|---|
| Dependency-free C table plus Swift adapter | 150.77 s | Rejected: no improvement, and conversion copies strings at runtime |
| Dependency-free Swift data module plus adapter | 145.01 s | Rejected: single 1.4% difference versus the initial baseline does not justify the module change |

The C encoding fixture passed Unicode, embedded NUL, binary byte and unchanged
output checks. Those experimental files/tests were removed after rejection.
Package.swift, the asset generator, generated assets and the UI test file were
restored byte-for-byte to their state at the start of this iteration. No asset
representation change remains in the repository.

## Final validation

The final wrapper passed two full runs of **3,748 tests across 55 bundles**.
The first took 156.59 seconds including compilation of all test targets into the
fresh scratch cache; the second warm full-command run took 21.12 seconds. These
are validation timings, not a new before/after claim for the test suite.

Four runner regression tests passed, including exact build selection/argument
forwarding, automatic-batching opt-out, explicit compiler overrides, release and
Linux defaults, binary-directory cache behavior, and full-suite history handling.
Shell syntax and `git diff --check` passed. No compiler warnings appeared in the
clean builds, final suites or shared-runtime rebuilds. Native Linux tests were
not run in this macOS session; its build behavior is unchanged.

The shared-runtime source was restored and rebuilt after the final guard. The
task-owned scratch build was then removed to reclaim disk space; the user's
regular build cache was not deleted or modified by these experiments.

A [subsequent tuning round](clean-build-followup.md) tested one compiler batch
and twelve build jobs against this retained setting. Neither delivered a reliable
further clean-build improvement, so this two-batch default remains in place.
