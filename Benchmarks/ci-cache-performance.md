# Linux and macOS CI cache benchmark

Measured on GitHub-hosted runners on 2026-11-10. **The per-revision PR cache proposal was rejected.** Uploading the complete build erased the Linux saving, increased the macOS PR-relevant subtotal, and the macOS shared-runtime measurements did not satisfy the no-slowdown guard.

The [final comparison](https://github.com/mp-consulting/homeswift/actions/runs/42844652018) passed all four jobs: Linux before/after and macOS before/after. Every successful full suite ran **3,746 tests on Linux** and **3,748 on macOS**. Both policies also passed all-product debug/release builds, restart checks, and five shared-runtime rebuilds. macOS checked embedded assets. No compiler warnings were found in the collected logs.

## Retained changes

- `Scripts/ci-test.sh` drains a finite `tee` stream before returning the test exit status. The former following `tail` could be killed before a large failure log reached CI. This also removes the fixed final one-second wait.
- Cache keys include architecture and toolchain/platform identity: Xcode/SDK on macOS, OS/C compiler on Linux. This is a cache-compatibility safeguard, not a measured clean-build speedup; changing the namespace incurs an initial cache miss.
- PRs retain their first successful cache; main retains per-commit caches. The existing reachable PR-head provenance is retained, rather than depending on an old synthetic merge commit being present in a future checkout.

The build engine, compiler flags, test selection, and test concurrency were unchanged in this comparison. Full coverage here means the complete existing suite; this experiment did not add instrumented line-coverage collection.

## Final warm comparison

Seconds, lower is better. “Before” restores the first successful PR-style cache; “after” restores the preceding source revision and uploads a new cache. The final repeat used the same fixed cache inputs as the preceding attempt, so rerunning did not give the candidate an extra warm-cache advantage. Both policies used the corrected logging wrapper.

| Measurement | Linux before | Linux after | macOS before | macOS after |
|---|---:|---:|---:|---:|
| Full debug build | 34.17 | 18.25 | 70.07 | 56.14 |
| Test build + complete suite | 41.32 | 42.28 | 114.77 | 119.01 |
| Full release build | 136.32 | 27.49 | 262.11 | 100.35 |
| Cache restore | 33 | 28 | 26 | 37 |
| Cache save | 0 | 129 | 0 | 50 |
| Debug + tests + release + cache I/O | **244.81** | **245.01** | **472.95** | **362.50** |
| macOS PR-relevant subtotal: debug + tests + cache I/O | — | — | **210.83** | **262.15** |
| Shared-runtime rebuild, median of five | **2.21** | **2.13** | **3.68** | **6.02** |

These are measured subtotals, not complete workflow wall times: runner queues, checkout, package installation, asset/restart checks, artifact uploads, and the extra rebuild probes are excluded. The benchmark deliberately builds release products on both platforms; ordinary macOS PR CI does not. Its relevant subtotal therefore excludes release compilation. Main already used per-commit caches before this proposal.

The Linux build/test/release commands fell from 211.81 to 88.01 seconds, but the extra cache upload consumed the saving. macOS release work benefited from the fresher cache, but its ordinary PR workload became slower. Independent hosted runners introduce noise: the macOS shared-runtime result is not proof of a causal compiler regression, but it does **not** establish the required non-regression. The proposal was therefore removed instead of relaxing the guard.

## Cold-build controls

Both policies started without a build cache and used identical Swift source and compiler settings. These differences demonstrate runner variability, **not a clean-build improvement caused by cache keys**.

| Measurement | Linux before | Linux after | macOS before | macOS after |
|---|---:|---:|---:|---:|
| Clean full debug build | 318.79 | 239.66 | 438.97 | 413.74 |
| Test build + complete suite | 376.10 | 299.97 | 568.59 | 467.23 |
| Clean full release build | 676.17 | 504.63 | 953.15 | 800.34 |

The [cold run](https://github.com/mp-consulting/homeswift/actions/runs/42834850436) passed both policies on both platforms. No attributable clean-build speedup is claimed for this CI-only change.

## Method and failures

Linux used the workflow's `swift:6.2` container (Swift 6.2.4, four CPUs); macOS used `macos-26`, Xcode 26.6 / Swift 6.3.3 (three CPUs). Neither selected a build engine explicitly. These hosted toolchains differ from the local Swift 6.4.2 machine used in earlier reports.

The isolated branch `codex/ci-cache-benchmark-20261110` froze the current working-tree source. The seed commit was `c4aa3754`, followed by a comment-only MCP revision (`6d17cc66`) and an independent comment-only Elgato Key Lights revision (`c6b5df6b`). The final logging-corrected repeat was `ec335c39`. Cache restore logs confirmed the original `first-success` cache for before and the `6d17cc66` cache for after. Five comment-only edits to `PluginHost.swift` each ran `Scripts/build.sh --all`; the exact source was then restored. Probe artifacts were never saved into the benchmark caches.

This push workflow models PR cache lifecycles in a separate cache namespace; it does not test GitHub's PR merge-ref provenance or the new SDK fingerprint itself. There were no test filters or exclusions, and no production source behavior changes between policies.

Failures are preserved in the [raw results](ci-cache-performance-results.json), rather than omitted from the record:

- Initial setup rejected an unpinned upload action. It was pinned before any benchmark builds ran.
- The [first cached revision](https://github.com/mp-consulting/homeswift/actions/runs/42841686904) hit a Linux Ring motion-test failure. The complete unchanged job passed on rerun.
- The [first final comparison](https://github.com/mp-consulting/homeswift/actions/runs/42843286901) failed both macOS suites. The candidate failed the same Ring test while waiting for motion to reset. The baseline exited nonzero, but its diagnostic was truncated by the old log wrapper, so its cause is unknown.
- After fixing output draining, the complete comparison passed on both platforms. No Ring assertion, fixture timing, test, or concurrency limit was changed. Those timing-sensitive failures remain a reliability finding; the green repeat does not prove they are fixed.

Nine benchmark-only caches (10.19 GB) were removed after completion. The benchmark branch and GitHub run records remain available; the working branch was not committed or pushed.

## Logging-wrapper check

Five alternating local invocations of the same immediately completing fake worker measured median wrapper overhead of **2.048 → 1.056 seconds**. This isolates removal of the fixed final wait; it is not a claimed one-second reduction in every hosted workflow's wall time. All five runner regression checks pass, including complete delivery of 200,000 output lines and a final diagnostic for both successful and failing workers, with exit status preserved.
