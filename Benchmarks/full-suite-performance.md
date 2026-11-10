# Full-suite performance and clean-build profiling

Measured on 2026-11-10: Mac14,7, 8 cores, 16 GiB RAM, macOS 27.2,
Swift 6.4.2, debug configuration, default SwiftPM engine (swiftbuild).
The baseline is the working tree at the start of this iteration, including the
previous batching, slowest-first scheduling and focused-run improvements—not git HEAD.
[Raw measurements, including failed trials](full-suite-performance-results.json).

## Retained results

Times are wall-clock seconds; medians unless stated otherwise.

| Operation | Before | After | Samples |
|---|---:|---:|---|
| Full test command, warm build included | 29.47 | 22.01 | 2 successful baseline runs; 4 final runs |
| Shared-runtime edit, rebuild all products | 6.48 | 5.95 | 3 each |
| Camera stream-claim stress test | 3.445 | 0.319 | 3 each |
| Parser generated-input comparison | 0.444 | 0.355 | 3 each |
| Binary-directory lookup alone | 0.652 | 0.051 | 3 each |

The final full-suite command is about 25% faster than the successful baseline
median. This is a small, variable sample: the two successful baseline runs were
32.73 and 26.21 seconds; a third failed after 74.47 seconds when
`writesOfOneRequestRunTogether` exceeded its 60-second limit. That failed run is
recorded, not included in the successful-run median. Final runs took 21.78,
21.75, 22.71 and 22.24 seconds. Each passed **3,748 tests in 55 bundles**.
No tests were filtered out of those runs.

Retained changes:

- The macOS default is 16 simultaneous bundles with 4 tests each, retaining the
  previous maximum of 64 concurrent tests. Slowest-first scheduling remains.
  CI's explicit 2 × 4 setting and Linux's width of 8 are unchanged.
- Parser results use structured equality instead of sorted-header formatting and
  Base64 encoding. All 5,000 generated inputs and three buffer forms remain;
  incomplete-buffer comparisons now check bytes rather than only byte counts.
- The camera claim stress fixture uses a loopback local address, avoiding host
  interface enumeration on every winning claim. All 2,000 rounds and eight
  contenders remain, as do the separate address-selection/routing tests.
  A stack sample identified interface enumeration as the dominant cost; sampled
  timings were not used in the table.
- Common test invocations cache SwiftPM's binary-directory answer. Package,
  toolchain, configuration, arguments and relevant environment changes invalidate
  the cache. Missing/corrupt entries, unsupported options or unavailable Python
  fall back to SwiftPM. The normal build still runs before this lookup.
- The sweep exposed two test synchronization bugs: Adaptive Lighting now waits
  for the automatic update it already scheduled; Tapo waits for both availability
  and the reported value. Imou's actual siren reset now uses the existing
  write-safe reset helper, preserving a reset that finishes before a write returns.
  These three regressions each passed 30 additional repetitions.

## Selection and shared-runtime guard

Exploratory runs tried 2, 4, 8, 12 and 16 bundles with different per-bundle widths.
A subsequent alternating full-command matrix restored the same initial ordering
estimates before every run. Successful medians were 26.05 seconds at 8 × 8,
27.05 at 12 × 4 and 23.79 at 16 × 4. That matrix also exposed the Imou and Tapo
races; an earlier 12 × 4 trial exposed the Adaptive Lighting race. All failures
remain in the raw results. The four final runs above used the selected default
and the fixes, with ordinary learned ordering.

The rebuild guard appended a distinct comment to
`Sources/HomeswiftPlugin/PluginHost.swift`, then ran
`Scripts/build.sh --all --scratch-path ~/Library/Caches/homeswift-build`, three
times before and after. The original source was restored and rebuilt afterward.
Before: 9.65, 6.48, 5.93 seconds. After: 6.62, 5.95, 5.93 seconds.
There was no measured regression; the warmest samples were effectively equal.
The package/module graph, compiler settings and build wrapper were unchanged by
this iteration. This is a regression guard, not evidence that shared-runtime
compilation itself became faster.

## Clean full builds: experiments rejected

A separate scratch directory contained dependency checkouts/artifacts but no
compiled outputs. `Scripts/build.sh --all --disable-automatic-resolution` built
all products using the default engine. Compiler statistics were enabled with
`-Xswiftc -stats-output-dir -Xswiftc <directory>` in both runs.

| Experiment | Time | Decision |
|---|---:|---|
| Clean all-product build, default jobs | 174.85 s | Baseline |
| Clean all-product build, 12 jobs | 170.44 s | Do not change default; one 2.5% difference is insufficient evidence |
| Generated asset rewrite, incremental median | 5.94 → 6.02 s | Rejected; original representation restored |

The asset experiment replaced a large dictionary expression with typed dictionary
assignments in the same file and target, preserving the asset data. Each trial
forced recompilation with a new comment. It provided no gain; neither its source
nor a generator change was retained.

Compiler statistics identify batch jobs containing Matter's `Cluster.swift`
(13.60 seconds), UI's `UIServer.swift`/`VaultRoutes.swift`/`WebAssets.swift`
(11.69 seconds), Matter module emission (11.13 seconds), and MCP module emission
(8.55 seconds) as major costs. These are overlapping compiler jobs, not additive
wall times or isolated per-file costs. The large implementation jobs spend much
of their time in SIL/LLVM generation. No module split or compiler workaround was
introduced on the basis of this profile. **No clean-build speedup is claimed.**

## Validation and reproduction

Run the normal full suite with:

```sh
Scripts/test.sh --scratch-path ~/Library/Caches/homeswift-build
```

Override `HOMESWIFT_TEST_BUNDLES` and
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` to repeat pool comparisons.
Use the same machine, idle background load, scratch directory and ordering
history; prepare binaries before warm-command measurements. Direct isolated
measurements used SwiftPM's testing helper with the individual test filter.

All four final suites, 90 race repetitions and three runner regression tests
passed. Runner tests exercise cache invalidation, continued normal builds on
cache hits, and Linux argument forwarding. Shell syntax and `git diff --check`
passed. The measured clean builds, final test build, final suites and shared
rebuilds emitted no compiler warnings. Native Linux execution was not available
in this macOS session; CI's Linux path remains unchanged.
