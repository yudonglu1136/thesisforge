# Consumer data consistency — 2026-09-23

## Incident and scope

Research showed AMZN USD 253.71 on 2026-09-18 at the 2026-09-22 cutoff.
Read-only production SSM `cdc58a11-1703-430f-abdd-498e2cc21d05` confirmed
that both archived model stores retained that close, while the canonical Fact
OS reader, executed as the actual `webapp` user, returned USD 258.45 on
2026-09-21. The latter was already installed: ingestion was not the cause of
this particular discrepancy. Active data release:
`5c318a56abe766f1e74e41ac2a84c7efd80d5d612649af88d99dda15b46f3e84`.

## Corrections

- A request-local, batched canonical RAW_CLOSE adapter now feeds Research,
  Guru company previews, opportunity lists, Fundamentals model comparisons,
  private scenario calculation/save/review, watches and research allocations.
  No missing canonical quote falls back to an archived model close. Failed
  reads produce a typed unavailable response. Currency is owned by the quote,
  not inherited from the model. The explicit Fact OS rollback mode retains
  the released SQLite path; it does not enable an external provider.
- Automatic reverse DCF requires matching quote/model currency. Unknown or
  mismatched currency disables the reverse solve and iso-value curve, without
  disabling forward scenario math. Explicit targets retain scenario currency.
- The overview curve and headline use the same quoted-price basis; split-
  adjusted series remain separate for returns. Fact-only company research
  retains its raw-price curve and does not require a valuation model.
- Company, opportunity, valuation and portfolio caches follow pinned data
  release identity. Current valuation caches also include the UTC date.
  Unversioned Discover URLs revalidate instead of retaining an old data release
  through browser stale-while-revalidate. History failures/corrections cannot
  reuse a ready company-history cache.
- Fundamentals discovery and company detail/Research share the repository's
  deterministic eight-observation metric calculation. Missing quarters retain
  calendar holes, not row-number substitutions. Normal 52/53-week quarter
  spacing is tolerated; short/ambiguous periods remain unknown. Net disposal
  cash flows are not converted with `abs(capex)` into capital spending.
- Current valuation financial cards use reported SF1 FCF, otherwise CFO plus
  signed capex. Archived FCFE/DCF calculations are unchanged. The detail price
  divergence window now matches discovery's one-year prior-session convention.

Financial method: `fact-os-business-change-2026-09-23-comparable-quarters`.
Old saved observations remain immutable; method changes are explicit on review.

## Consumer boundary matrix

| Consumer | Current read | Preserved separately |
| --- | --- | --- |
| Research / Guru company preview | Fact OS raw close, cutoff, currency, generation | Published model period/inputs/weights |
| Fundamentals / Research financial detail | Canonical AR facts and one repository metric calculation | Historical available-at and missing periods |
| Valuation / Portfolio model comparison | Fact OS raw quote and release-aware cache | Model ledger, issuer unit/currency guards |
| Home / Portfolio account value | Verified broker statement and dated NAV | Never replace broker marks with a market quote |
| Research allocations / scenarios / watches | Shared quote for current calculation/review | Existing saved snapshots and personal inputs |
| 13F / Guru ownership | Existing quarter, split normalization and strict/proxy contracts | Not live trades or daily cash flows |
| AI Insights | Existing immutable generation/snapshot | Saved evidence and fixed ranking population |
| Strategy / CTA / backtests | Existing audited execution/total-return series | No automatic rewriting with raw comparison prices |

## Verification

Reproducible read-only command:

```sh
node scripts/audit-consumer-data-consistency.mjs <research.sqlite> 2026-09-22
```

The adjacent JSON records actual local canonical reads for AMZN, MSFT, NVDA,
GOOGL and MU. Research, Guru and Valuation quotes/curve endpoints matched;
six key financial metrics matched list versus detail for all five. AMZN's
published model remains 235.6928225956114 dated 2026-07-31. Before/after SHA-256
of all tested model input/output ledger rows is identical. This is a bounded
cross-consumer probe, not a claim that every provider record is error-free.

Workspace tests: 1,693 Node passes, 15 existing skips, zero failures;
215 Python passes; 60 transport/cache passes; bilingual literal audit and
`git diff --check` pass. The initial full Node run exposed three source-less
route fixture failures, fixed with the optional source guard and rerun. An
added Python regression first failed on positive capex being treated as
spending; it passes after the shared metric correction.

The exact staged source (excluding concurrent work) was independently tested:
1,688 Node passes, 15 existing skips, zero failures; 215 Python passes;
60 transport/cache passes. The final currency regression first reproduced an
incorrect successful reverse solve and now passes; 95 targeted tests pass.
The workspace storage-layout audit still reports eleven pre-existing paths
(one runtime valuation source database and ten retired sibling directories).
They are not part of this patch or code-only archive; none was deleted.

## Release and rollback

Code-only repair: no raw fact, model SQLite, private journal or broker write,
no backtest refresh, no new scheduler or provider key. Package only committed
repair files; unrelated concurrent work remains uncommitted. The previous EB
version `guru-repair-175b4a2` is the code rollback target. Rolling back code must
not restore or overwrite live user databases. Exact-source package and actual
production verification are recorded after deployment, not inferred from
local tests or EB Green.

The active API manifest currently names only the canonical group. Independent
AI/13F/research artifacts have their own existing release contracts; this
repair does not claim that all six staged daily derived groups are activated,
nor that the first future scheduled run has already completed. Published
valuations/backtests are intentionally not silently regenerated by a price
read. UK/non-USD or unresolved listings remain unavailable where no verified
comparable quote/claim conversion exists.
