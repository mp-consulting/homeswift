# Review since v0.9.0

Review date: 2026-10-25. Code baseline: `v0.9.0..f2aadca` (183 changed files, including generated
assets and images). This is a direct source review, not a Claude Security scan or an independent audit.
Documentation and generated website assets were refreshed afterwards. The review itself did not create a release tag.

## Findings resolved

All three findings below are fixed in the release working tree.

### Restart retries retained an expired deadline

`waitForRestart` now gives each attempt a fresh 90-second polling deadline while retaining the original
restart timestamp for the process-age comparison. A fake-clock regression checks the initial timeout,
a retry that continues polling after an unsuccessful response, and dismissal when the process recovers.

### Reconnecting did not reconcile accessory state

On the event stream's hello, the UI now fetches `/api/accessories` and updates existing widget and group
models in place. Characteristic object references, layout, scroll and unsaved forms stay intact. Events received
while fetching are buffered and replayed afterwards, so newer values win over the snapshot. A response from
an abandoned stream is ignored, and a failed snapshot does not discard buffered live events. Missing accessories
are marked unavailable. Camera motion and recording indicators are refreshed without replaying doorbell presses.
This runs after explicit restarts and automatic SSE reconnects.

### Group controls bypassed translated labels

Visible labels and accessible names now use `HomeswiftI18n.message`, the characteristic translation path used
by widgets. Regression checks render group controls against the real French, Spanish and Portuguese catalogs.

`Scripts/test-reconnect.mjs` and the expanded `Scripts/test-accessory-groups.mjs` cover these fixes and run in CI.

## Security review

No confirmed new exploitable security vulnerability was identified in the reviewed paths. This is not a
claim that every possible vulnerability has been ruled out. The assessment covered the new/changed server
routes, Wingman pairing and mirroring, webhook authentication and headers, accessory writes and groups,
restart lifecycle, browser injection sinks, and build/site scripts. Unchanged authentication, OAuth and
cryptographic implementations were consulted where relevant, not independently re-audited. Generated Swift
and website copies were checked through their source generators/parity tests rather than treated as separate
implementations. Linux and a real signed Wingman session were not exercised in this review.

Relevant checks:

- Wingman requires a pinned certificate before sending its bearer token. Pairing uses the supplied pin.
- Plugin configure actions retain admin scope; plugin tool results conceal secrets through the session vault.
- Mirrored accessories stay outside the HAP database and controller access. Security characteristics retain
  the catalog's confirmation restrictions; dashboard grouping does not add a server-side bypass.
- Webhook credentials and custom header values are masked on reads. Header validation rejects control characters,
  reserved transport headers and conflicting Authorization settings; delivery errors report status, not echoed bodies.
- Port checks remain administrative. A successful check is a point-in-time probe, not a port reservation.

## Simplification opportunities

1. Further isolate restart polling into a small state machine. The retry deadline is now separate.
   Use a boot identifier instead of inferring process replacement from uptime plus a five-second tolerance.
2. Share characteristic labels and control builders between groups, widgets and the scene builder. Group controls
   currently duplicate range handling and do not intersect `validValues` or different step grids; simply taking
   the largest `minStep` does not guarantee a value every member accepts.
3. Consolidate the appended mobile-navigation CSS blocks into one component section. Several successive overrides
   make the final hover, active and layout rules harder to trace.
4. Give Natural Lighting an explicit reconciliation/cleanup path for deleted accessories and services. Its observer
   table otherwise retains obsolete characteristic objects until that entry is reconfigured or the process exits.

## Validation and release preparation

The focused Swift suites passed: Wingman, Natural Lighting, webhook authentication, mirrored accessories/cache,
accessory groups, translation checks and embedded-file parity. The Node group and temperature-indicator checks
passed. The fixture browser checks passed for widget sizes, alignment, toggles, hold actions and menus.
The design-system browser checks passed for all 252 characteristic stories, 14 widget renderers in four sizes,
keyboard controls, mobile layouts, languages and isolated transport, with no browser errors.

The website parity check initially failed because its copied UI runtime was stale. Regenerating with
`node Scripts/design-system.mjs` updated those copies. The release changelog, main and Wingman READMEs,
UI/widget guides and demonstration screenshots were refreshed. Unaffected device-plugin READMEs retain their
existing setup instructions. These changes are included in the 0.11.0 release preparation.

The full macOS test run completed successfully: 1517 tests across 18 test bundles.
The later link-style fix was embedded and synced to the public design runtime; live-browser inspection
confirmed button links no longer match the text-link hover rule.

After the three fixes, the reconnect/group/temperature Node regressions, focused Swift translation/group/embedded
asset tests, website parity check and fixture screenshot checks passed. A local restart returned a healthy
backend and the in-app browser eventually dismissed its overlay automatically, without reloading. The observed
browser recovery was delayed; this check does not establish the cause of that delay or a recovery-time guarantee.
The floating hamburger button alone now uses translucent colour and backdrop blur; its menu panel remains solid.
