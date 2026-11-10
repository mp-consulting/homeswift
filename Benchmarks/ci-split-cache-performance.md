# Split dependency/project CI caches

Measured on GitHub-hosted Linux and macOS runners on 2026-11-10. **The Linux split is retained; macOS keeps its whole-build cache.** Both platforms passed the full suites and shared-runtime rebuild guard. Linux became faster overall; macOS’s smaller upload did not recover its extra restore/partition cost.

The default build engines, compiler settings, test selection, and test concurrency are unchanged. Successful suites ran all **3,746 Linux tests** or **3,748 macOS tests**. “Full coverage” means the complete existing suite, not newly instrumented line coverage. No clean-build speedup is claimed: this change reduces recurring cache-upload work.

## Linux results

Both policies ran sequentially on the same runner, with the same source revision and equally fresh input caches. The first comparison ran whole-cache before split-cache; the follow-up reversed that order and changed another plugin. Both comparisons passed complete debug/release builds, full suites, restart/asset checks, and five shared-runtime rebuilds per policy.

| Measurement (seconds) | First: whole | First: split | Reversed follow-up: whole | Reversed follow-up: split |
|---|---:|---:|---:|---:|
| Full debug build | 19.16 | 17.24 | 15.71 | 18.07 |
| Test build + complete suite | 47.33 | 49.35 | 48.32 | 47.34 |
| Full release build | 28.73 | 29.09 | 20.79 | 21.67 |
| Cache download/extraction actions | 29 | 27 | 28 | 29 |
| Reassemble downloaded partitions | 0 | 2.18 | 0 | 1.77 |
| Partition/fingerprint + reassemble after save | 0 | 10.03 | 0 | 8.17 |
| Cache compression/upload action | **144** | **118** | **160** | **127** |
| Complete measured phase | **271** | **256** | **276** | **257** |
| Shared-runtime rebuild, median of five | **2.662** | **2.645** | **2.552** | **2.462** |

The complete phase runs from cache restore through cache save/reassembly, including source invalidation, full builds/tests, restart and asset checks, metadata handling, and step-transition overhead. It excludes checkout/tool installation, initial source dating, runner queues, artifact upload, and the extra shared-runtime probes. This is more complete than a sum of selected command timings, but is not total workflow wall time.

The reversed follow-up saved **33 seconds (20.6%)** in its compression/upload action and **19 seconds (6.9%)** in the complete measured phase. The first comparison saved 26 seconds and 15 seconds respectively. Build command times were broadly unchanged; the benefit is cache handling. Both observed shared-runtime medians were lower with the split, including when it ran first.

Linux now installs Python 3 for the partitioner. A [separate setup check](https://github.com/mp-consulting/homeswift/actions/runs/42881468656), installing Python after the original Avahi dependencies in `swift:6.2`, measured **5.427 seconds** of additional installation time. Both benchmark arms already had Python for their timing harness, so the phase table excludes this incremental production cost. Subtracting it from the observed phase savings leaves roughly **10–14 seconds** per cache-writing job. That is an estimate using a separate setup measurement, not a measured complete-workflow speedup; production installs both sets of packages in one command.

The compressed project archive is approximately 842 MB, compared with a 1,145 MB whole archive; about 303 MB of unchanged dependencies is not uploaded again. The dependency generation remained identical across both project revisions, and both dependency-save steps were skipped.

[First corrected comparison](https://github.com/mp-consulting/homeswift/actions/runs/42873021785), [reversed Linux follow-up](https://github.com/mp-consulting/homeswift/actions/runs/42876347622).

## macOS results: split rejected

The [reversed-order macOS follow-up](https://github.com/mp-consulting/homeswift/actions/runs/42878079163) passed both complete suites and saved both fresh cache keys successfully. It ran the split policy first, then the whole-cache baseline on the same runner.

| Measurement (seconds) | Whole cache | Split cache |
|---|---:|---:|
| Full debug build | 23.41 | 48.51 |
| Test build + complete suite | 110.09 | 110.31 |
| Full release build | 77.97 | 87.86 |
| Cache download/extraction actions | 36 | 74 |
| Reassemble downloaded partitions | 0 | 1.34 |
| Partition/fingerprint + reassemble after save | 0 | 15.14 |
| Cache compression/upload action | **42** | **33** |
| Complete measured phase | **297** | **387** |
| Shared-runtime rebuild, median of five | **3.625** | **2.926** |

The dependency generation was reused and its upload skipped. The project archive is approximately 767 MB versus 1,117 MB for the whole cache. Nevertheless, the 9-second upload saving was smaller than partition/reassembly overhead alone. Downloads were also slower in this run. Hosted cache throughput and some cache-restored core recompilation varied, so the 90-second total increase is an observation, not proof that every macOS run would regress by that amount. It does not demonstrate a worthwhile speedup, so **no macOS cache changes are retained**.

The first corrected macOS comparison passed on a complete unchanged retry and had shared-runtime medians of 5.064 → 2.643 seconds. Its baseline save encountered an existing cache key, making it unsuitable for a fresh-upload comparison. The table uses the clean follow-up instead. Both orders showed no measured shared-runtime regression; the rejection is based on overall cache/build cost, not a failing rebuild guard.

## What changes in CI

Linux saves dependency outputs separately from project outputs. Each project snapshot names the exact dependency generation it was built with. The helper reassembles the usual `.build` tree before SwiftPM runs and preserves artifact contents, modes, timestamps, and symlinks. The project partition holds local targets/products, tests, the joint build database, provenance, and planning/link files; dependencies hold dependency sources and stable compiled outputs.

Cache compatibility includes platform, architecture, toolchain/OS/C compiler, manifests/lockfile, build settings script, and partitioner version. A new compatibility key incurs an initial cache miss. If dependency inputs or compiled outputs change, a new dependency generation is uploaded too. A missing partition is recoverable by SwiftPM; a mismatched pair is rejected before files are moved.

**Cache refresh frequency is unchanged:** main saves per commit; PRs retain their first successful cache. This does not revive the rejected proposal to upload a new whole build on every PR revision. PR cache hits have no upload to save, and may pay a small extra restore/reassembly cost (about 0.2–2.8 seconds in the Linux comparisons).

The benchmark explicitly builds all debug products and release products on both platforms. Ordinary macOS PR CI continues to omit release compilation. The test and release commands in production CI are unchanged.

## Method, corrections, and failed attempts

Linux used Swift 6.2.4 in the normal `swift:6.2` container with four CPUs. macOS used Swift 6.3.3 on a three-CPU `macos-26` runner. Neither workflow selected an engine explicitly.

The isolated branch is `codex/ci-split-cache-benchmark-20261110`. Application code was frozen at the earlier green snapshot `ec335c39`; only comment edits distinguish the benchmark revisions. Concurrent UI work in the root checkout was left untouched. The experiment validates the cache change against that snapshot, not unfinished unrelated UI changes.

The original cold seed was `9c0a7d41`. A comment-only MCP revision (`56aa9167`) exposed an ownership mistake: SwiftPM rewrites output-file maps and project autolink files inside external target directories. A [cache-only diagnostic](https://github.com/mp-consulting/homeswift/actions/runs/42869546875) found **94 changed entries, all with identical contents and only different mtimes**. These files now stay with the project, preserving their dates alongside its database and avoiding false dependency-generation changes. The initial partitioner was discarded.

The corrected seed (`c4001eff`) reused already-verified whole-cache outputs and passed full validation. The first corrected project edit was Elgato Key Lights (`b843b3ba`); the independent follow-up was Weather (`e4938bf6` for Linux, `5ec93c7f` for macOS; identical application source). Both policies restored outputs of the same preceding revision. Five comment-only edits to `Sources/HomeswiftPlugin/PluginHost.swift` each ran `Scripts/build.sh --all`; exact source was restored afterward. Cache snapshots were saved before these probes.

Failures were preserved, with no test filters, weaker assertions, or concurrency changes:

- The first unfinished-UI snapshot failed three design-token tests on both platforms and two additional AddWhileRunning tests on macOS. The benchmark moved to the known-green application snapshot.
- The original partitioner's macOS candidate failed TP-Link's `aStripIsItsOutlets`. Its retry was cancelled after the cache-ownership defect was identified, and the candidate was replaced.
- The corrected Linux seed failed `tvsListTheFavourites` **before splitting**. The entire unchanged job passed on retry.
- The first corrected macOS candidate failed Zigbee2MQTT's `coverWithoutMotorState`. The entire unchanged comparison passed on retry. Its repeated baseline cache key could not be reserved, so that retry's baseline save duration is not a valid fresh-upload measurement.

These failures remain suite reliability findings; passing retries do not establish that they are fixed. The retained Linux comparisons both passed their full suites on their first attempts.

## Local and workflow checks

Five partitioner regression checks cover both build layouts, mixed project/dependency target directories, exact artifact round trips, stable dependency generations despite rewritten project plans, incompatible generations, overlap rejection, partial caches, and PAX archive round trips. Five existing test-runner regression checks also pass.

A small real Swift package on the local default engine builds and runs after a complete split/restore, a project-only restore, and a dependency-only restore. Workflow validation checks YAML, pinned action revisions, step references, shell syntax, unchanged test/release commands, and the unchanged macOS production job.

Detailed command timings, test counts/failures, workflow steps, and the dependency diagnostic are in [the raw results](ci-split-cache-performance-results.json). No compiler warnings were observed in the successful measured build logs.

All experiment caches were removed after their sizes and results were recorded. The isolated benchmark branch and run records remain available; at benchmark completion, the working branch had not been committed or pushed.

## Commit scope

This change is isolated from the earlier uncommitted build/test optimizations. The benchmark above measures the frozen performance-work snapshot, not a fresh benchmark of the main-branch source. Only Linux cache partitioning, its integrity checks, and this report are included. The existing main-branch macOS job and build/test commands are preserved. Cache compatibility also hashes the actual test/build entry-point scripts.
