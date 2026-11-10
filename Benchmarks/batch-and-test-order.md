# Batch generation and slowest-first test scheduling

Follow-up to [the default-engine work](build-test.md), measured on 10 November
2026 on the same 8-core, 16 GiB Mac14,7, macOS 27.2, Apple Swift 6.4.2.
Both sides use the **default engine (Swift Build)** and the existing external
build cache. [Raw runs, failures, commands and source hashes](batch-and-test-order-results.json).

| Workload | Before | After | Interpretation |
|---|---:|---:|---|
| Generate the same 68 outputs | 21.48 s | 0.54 s | Medians of three runs; 97.5% less time, about 40× faster |
| Full build-and-test command, successful runs | 27.68 s | 23.61 s | Two passing runs on each side; about 15% less time |
| Bundle execution, successful runs | 20 s | 15 s | Median of the runner's whole-second measurements |
| Shared-runtime rebuild, all products | 10.76 s | 8.13 s | Three interleaved pairs; no slowdown observed |

The shared-runtime row is a regression check, not a claimed compiler optimization.
The captured and current build scripts are byte-identical. `Package.swift`,
application source, generated data and existing test assertions are unchanged.
All measured builds emitted zero compiler warnings.

## What changed

`bin/dev embed` now invokes `swift Scripts/embed-assets.swift all` once. The batch
uses the same implementations as the individual `plugin`, `web` and `prompts`
commands, and includes Govee scenes. Existing individual commands still work.
It includes the Assistant prompts and both Shelly schemas. The old driver omitted
the prompts and second schema and guessed `ShellyPlugin` for the main schema,
which actually belongs to `ShellyNGPlugin`.

The generation comparison normalizes that difference: 68 separate Swift
invocations versus one invocation producing exactly the same 68 outputs. It is
not a claim that the old, unmodified 66-call driver generated those extra files.
A snapshot of all 70 generated Swift files verified unchanged SHA-256 hashes,
modification times and inodes after each batch run. The two additional generated
files outside the batch were also preserved.

The macOS runner retains its eight-bundle/eight-test local limits. It orders the
current bundle list by estimated duration, longest first. `Scripts/test-durations.tsv`
provides initial estimates; a successful full run atomically saves fresh durations
to `<bin-path>/.homeswift-test-durations.tsv`. Filtered, customized or failing runs
do not replace the history. Malformed entries are ignored, removed bundles are
not reintroduced, and unknown bundles still run. Ordering must preserve the
bundle count or the runner fails. Linux's single-executable test path is unchanged.

## All suite outcomes

Every successful run executed all **3,747 tests across 55 bundles**. Four full
suite attempts were made on each side; two passed on each side. Failed runs were
not counted as successful performance results, and remain in the raw data.

| Run | Before | After |
|---|---|---|
| 1 | 53.00 s, UniFi Access gate-state failure | 25.24 s, passed |
| 2 | 26.14 s, passed | 21.99 s, passed |
| 3 | 24.57 s, UI import and Tado failures | 37.61 s, Reolink chime-reset timeout |
| 4 | 29.23 s, passed | 22.86 s, randomized WebRTC fingerprint-test failure |

The last failure is the previously observed test that replaces `A` in a randomly
generated fingerprint: a fingerprint containing no `A` remains valid, making the
assertion intermittent. These changes do not fix or weaken that test. With this
small, flaky sample, the suite improvement is indicative rather than a precise
universal speedup. Generation timing is substantially less variable.

## Shared-runtime regression check

Each trial prepended a different number of comment lines to
`Sources/HomeswiftPlugin/Slug.swift`, changing debug line information and forcing
compilation and relinking. Before/after command order was reversed in pair two.
All products were built on both sides, and the original source bytes were restored.

- Before: 11.988, 7.918, 10.762 seconds.
- After: 8.132, 7.683, 8.479 seconds.

No deprecated engine, compiler-optimization flag, reduced product scope or
application-module split was used for this comparison.

## Validation and use

```sh
bin/dev embed
bin/dev test
bin/dev test Govee
python3 Scripts/test-test-runner.py
```

Regression tests cover seeded and learned ordering, unknown/stale bundles,
malformed history, paths containing spaces, successful duration publication,
filtered runs and failed runs. The individual generator modes were checked for
changed-input regeneration and unchanged-input idempotence. CI now runs the
ordering tests and checks that batch generation preserves committed assets.

No cold-build, release-build or Linux timing improvement is claimed. The shared
runtime and test benchmarks ran sequentially, with cache preparation excluded.
