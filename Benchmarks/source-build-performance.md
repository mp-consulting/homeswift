# Source-level clean-build optimization

Measured on 2026-11-10: Swift 6.4.2, macOS 27.2, Mac14,7, 8 cores,
16 GiB RAM. All full builds used the **default swiftbuild engine**, debug
configuration, and the already-retained two-batch setting. No compiler tuning
was added. The baseline is the working tree at the start of this iteration,
including prior authorized optimizations, not git HEAD.
[Raw results](source-build-performance-results.json).

## Source change

`SceneArtwork.all` and `SceneTemplateLibrary.all` remain public, typed, lazy
stored `static let` properties. Each now calls a private `makeAll()` function
with an explicit return type. The large initializer expression is the function's
body. This lets module emission skip type-checking that body, while the normal
implementation compilation still checks and compiles it.

Ignoring indentation, the production diff is twelve added lines and two replaced
lines across `SceneArtwork.swift` and `LightShows.swift`. Both original initializer
expressions were hashed and compared after removing only the added indentation;
they match exactly. Names, ids, colours, steps, ordering and template behaviour
are preserved, including all 143 gallery entries. No package split, new target,
asset representation change, public API change or mutable cache was introduced.

Profiling ruled out broad rewrites of HAP definitions and output schemas: their
individual expressions were cheap compared with the two catalogue literals.
Those files and their generators were left untouched.

## Isolated compiler evidence

The MCP module-emission command was extracted from the baseline SwiftBuild task
metadata. It was replayed sequentially with its normal imports, SDK and compiler
options, adding expression-timing/statistics diagnostics and redirecting its
outputs to separate temporary directories. Only the two source files alternated.
The diagnostics were not used in the full-build timing runs or retained settings.

| MCP module emission | Before | After |
|---|---:|---:|
| Run 1 | 2.468 s | 0.882 s |
| Run 2 | 2.702 s | 0.863 s |
| Run 3 | 2.468 s | 0.851 s |
| Median | **2.468 s** | **0.863 s** |

This is approximately **65% less elapsed time for module emission**, not for the
whole build. Median semantic-analysis time fell from 1.973 to 0.483 seconds.
The original artwork expression took 1,045.53 ms and the light-show expression
307.69 ms in the first profile; neither is type-checked during module emission
after the refactor. The implementation compiler still processes both bodies.

## Clean full-product builds

Wall-clock seconds, including planning, compilation and linking:

| Pair | Before | After |
|---|---:|---:|
| 1 | 142.62 | 140.80 |
| 2 | 151.72 | 151.71 |
| 3 | 156.55 | 140.51 |
| Median | **151.72** | **140.80** |

The observed median is 7.2% lower, but **do not treat that as a reliable expected
whole-build gain**. Paired reductions ranged from effectively zero to 10.2%,
with a median paired reduction of 1.3%; the host was not isolated from background
activity. The isolated compiler result is much more repeatable. Median child-
process CPU time (user plus system) was 787.02 versus 783.20 seconds.
All six clean full builds passed.

Before each run, the task-owned scratch directory's `out`, `manifest.pif` and
`debug` outputs were removed. Dependency checkouts, repositories, artifacts and
workspace state remained; no network resolution was needed. OS/toolchain caches
were not flushed. Runs were sequential, without another benchmark/test build
beside them. Command for both source versions:

```sh
HOMESWIFT_BUILD_BATCHES=2 Scripts/build.sh --all --scratch-path /tmp/homeswift-source-build/scratch --disable-automatic-resolution
```

## Shared-runtime guard

The guard appends a distinct comment to `Sources/HomeswiftPlugin/PluginHost.swift`
and rebuilds all products three times, restoring the original bytes in a
`finally` block. This measures a steady-state implementation edit, not a public
API change that invalidates downstream source compilations.

| Series | Samples (seconds) | Median |
|---|---|---:|
| Before | 13.558, 6.233, 6.577 | 6.577 |
| Candidate, first guard | 12.325, 6.616, 6.219 | 6.616 |
| After initial validation | 8.841, 5.718, 5.628 | 5.718 |
| After successful full-suite validation | 8.571, 6.366, 6.176 | 6.366 |

The first candidate guard differed by 0.039 seconds in median (0.6%), within the
observed run variation. Subsequent guards were below the baseline median; no
steady-state regression was measured. These are regression checks, not evidence
of a shared-runtime compilation speedup. The package graph and build settings
are unchanged.

## Full coverage and validation

Two confirmed unfiltered full runs passed **3,748 tests across 55 bundles each**.
They took 35.74 seconds (including recompilation of the corrected fixtures) and
22.42 seconds. These are validation timings, not a test-suite speedup claim.
The four runner regression tests also passed. Each corrected fixture passed 30
additional isolated repetitions, for 60 successful repetitions in total.

Earlier failed validation runs remain in the raw results:

- The first failed only the UI embedding checks for `style.css` and `app.js`.
  Independent UI work updated the web files and generated assets during the
  initial validation window, after the timed clean builds. This task preserved
  those edits, confirmed the current generated output matched the web sources,
  and rebuilt. Their final observed modification times precede the successful
  validation runs. No UI source or asset changes were made by this task.
- The next run exposed a Reolink readiness race and a SmartThings test timing
  assumption. The Reolink test now waits for both sensor values that its push
  handler applies sequentially, retaining its assertions. The SmartThings test
  fixture accepts an injected slider delay, and this concurrency test uses the
  production 300-ms window instead of the fixture's scaled 300 microseconds;
  it still sends all five writes and requires exactly one command. Only test
  code changed; neither plugin's production behaviour changed.

All clean builds and the confirmed suites emitted no compiler warnings.
Shell syntax and `git diff --check` passed. Native Linux execution was not
available in this macOS session. The full suite's selection, assertions and
coverage were retained; the scene catalogue tests still validate every template
and all 143 gallery entries.

The shared-runtime source was restored and rebuilt after the last guard. The
task-owned scratch build was then removed to reclaim disk space. The regular
build cache was only read to copy dependency checkouts/artifacts.
