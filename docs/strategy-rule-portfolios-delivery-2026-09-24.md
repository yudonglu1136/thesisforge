# Rule portfolios completion

Scope: Quality Rank Top 10 and the Ackman quantitative proxy, alongside the existing
Strategy builder. The original implementation/test/commit delivery has now been
promoted to production under the subsequent explicit push/deploy authorization.
See [production verification](audits/strategy-rules-production-2026-09-24.md).
Existing unrelated Research, AI Insights and pipeline work is excluded.

## Defects reproduced before repair

- The draft API echoed `asOf` but returned future holdings, daily NAV and full-window metrics.
- The draft owner portfolio used rank-buffered trims, not the requested Top 10 sqrt sizing.
- Defaulting to the new dashboard displaced the existing Strategy builder workflow.
- The two request paths could overwrite newer state with a late response.
- Ackman lacked position weights and score-component evidence; the 10 MB candidate dump
  and hard-coded private-temp dependencies are not suitable runtime dependencies.

## Acceptance tracker

- [x] Explicit independent rule portfolios; sqrt(11-rank), 15% target cap, cash remainder.
- [x] Same engine replay, accounting/cost reconciliation and reproducible input receipts.
- [x] Historical cutoff applied to daily paths, holdings and all statistics.
- [x] Quarter-level rank, source metrics, contributions and weight changes.
- [x] Independent comparison toggles, rules and bilingual responsive UI.
- [x] Regression, performance, i18n, analyzer/build and browser validation (exceptions below).
- [x] Scoped commit; subsequent production promotion and live verification recorded separately.

The browser check caught a real integration regression: the shared curve painter
accepted arbitrary series but painted only five legacy IDs. A pixel-level test
reproduced the invisible Quality/Ackman curves before the painter was fixed to
include caller-supplied series while preserving legacy layering.

## Verification record

| Check | Result |
| --- | --- |
| Final Node suite | 1,703 passed; 15 skipped; zero failures |
| Targeted Flutter + existing workflow | 81 passed, including rendered pixels, 390px Chinese layout, evidence, toggles, historical quarters, retry and request races |
| Full Flutter | 588 passed; 32 failures, exactly the same failure-name set as the preceding release baseline; no new failure |
| Flutter analyzer / bilingual literal audit | Passed |
| Performance regression tests | 60 passed |
| Independent Python share-unit replay | 876 daily NAVs per strategy, 14 rebalances, costs, score/weights and five metrics reconcile within 1e-10 relative/absolute tolerance |
| Same-input replay | Byte-identical JSON, including source and implementation receipts |
| Desktop browser | English/Chinese, holding evidence dialog, historical quarter selection, complete/incomplete labels and actual curves checked |
| Production-mode Flutter build | Passed with AUTH_DEV_BYPASS=false; compiled JS SHA-256 `61b4fa97d20523692a9b02a747aa89b647706ee64684ba79a07c891c5e7c289e` |
| Fact OS storage content audit | Passed; raw duplicate bytes zero; no source facts or private stores changed |
| Repository storage-layout audit | Existing 11 findings remain: valuation-pit-source.sqlite plus ten retired sibling directories; nothing deleted |

The 32 pre-existing failures concern adjacent Discover/Research/Portfolio tests;
they are not silently waived as passing. The comparison baseline is
`/private/tmp/ai-heatmap-release-flutter.log`; this run is
`/private/tmp/strategy-rule-flutter-final-full.log`. Final server results are in
`/private/tmp/strategy-rule-node-final.log`. Browser verification is desktop;
390px verification is a Flutter widget test, not a claimed mobile-browser run.
The local visual-QA server exposes the new snapshot read-only and forbids POSTs;
it is not a claim that a new live custom-strategy calculation was submitted. The
existing builder is preserved and covered by the workflow regression tests.

API read microcheck: cold approximately 33ms, cached-read P95 approximately 3ms
(20 local reads). The JSON is about 734KB / 129KB gzip. This is not a cross-release
production load benchmark or a latency guarantee.

## Artifact and reproducibility

- Derived snapshot: `server/config/investor-style-dashboard.json`.
- SHA-256: `6f800cc44e5239b362451feb1b472625792e04236b4a6b00d28cdc6de2c7eb5b`.
- Source generation: `134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
- Engine commit: `868a5f029f81873df9102e56b52be7612027d2c6`.
- Coverage: 2023-01-03 through 2026-07-01, 876 sessions; 15 quarterly selections,
  of which 14 have completed return windows. The latest selection has no mature
  return. These are separate rule portfolios, not copies of Guru fund returns.

`scripts/build-rule-portfolio-inputs.py` takes explicit panel, metadata, candidate,
Treasury rate, original feature-adapter, frozen schedule, audited corporate-action,
Fact OS root and output arguments. Each input and the pinned generation is recorded
in the receipt. Rebuilding requires those authorized research inputs; they are not
raw datasets distributed with the application. The runtime needs only the compact
derived snapshot, not the old 10MB candidate file or any developer temp path.

Replay and independently validate a prepared bounded input directory:

```sh
node scripts/replay-rule-portfolios.mjs INPUT_DIR OUTPUT_JSON 868a5f029f81873df9102e56b52be7612027d2c6
python3 scripts/audit-rule-portfolio-snapshot.py OUTPUT_JSON INPUT_DIR/prices.csv
```

The optional immutable engine revision avoids including another task's unfinished
working-tree engine changes. This delivery deliberately does not commit those
changes, the older owner-compounder experiment, or unrelated research documents.
The superseded untracked UI draft was moved recoverably to
`/private/tmp/thesisforge-rule-portfolios-20260924/legacy-investment-investor-styles.dart.txt`.

## Remaining boundaries

- The original implementation request did not deploy. Subsequent authorization
  promoted code commit `3c12a8d` to Vercel and AWS; see the production audit for
  exact identities, fresh clean-source test counts and remaining warnings.
- This is a versioned research snapshot, not a newly enabled daily strategy
  publisher. Fact OS sync and saved user strategies are untouched.
- Do not label the entire old Strategy/Guru audit epic complete because these two
  rule portfolios are now implemented.
- Before production promotion, explicitly triage the existing full-suite/storage
  findings under the deployment contract and perform authenticated live checks.

## Research boundaries

The inherited research uses current-vintage facts filtered by original reporting dates;
it is not an archived-vintage PIT backtest. Selected rule variants were compared after
seeing outcomes and must remain exploratory, not independently validated alpha. The
inherited provider capital-return field is pretax EBIT/average invested capital, not
after-tax ROIC; its legacy comparison with an assumed WACC is a screening heuristic,
not proof of value creation. No real Ackman fund-return claim is made.
