# Rule portfolio matched holding intervals — 2026-09-24

## Change

Replace separate buy/sell price lists with FIFO holding-batch groups. Every
matched portion shows purchase date/price, sale date/price or range-end mark,
adjusted simulated units, interval basis, proceeds/mark value, allocated modeled
costs, net P&L and return on its interval basis. Sold and still-held portions have
separate summaries. Both rule strategies use the same component and calculation.

## Accounting contract

- `rule-range-attribution-v2`, with `fifo-post-cost-v1` interval attribution.
- Ordinary-security events now use actual differences between the existing
  simulation's post-cost holdings. Retain `preCostTargetNotional` and the
  explicit historical target-turnover fee basis. Do not rewrite published NAV,
  cost receipts, ranking, universes or Fact OS facts.
- FIFO is a disclosed presentation attribution rule, not a reconstructed broker
  tax-lot ledger. Prices/units are total-return-adjusted, not historical fills.
- For a clipped range, carry surviving original purchase batches into the
  opening closing mark, clear prior fees and reset the interval price basis.
  Opening-day executions are excluded except at the independent segment's
  inception. Preserve original purchase date/price as context only.
- Entry costs split proportionally across sold and remaining quantities; exit
  costs split across the matched lots. Open lots are marked, never sold at the
  range boundary. Any standalone historical fee remains an explicit fee row.
- Verify inventories, gross P&L, costs and net P&L; fail closed on mismatch or
  overselling. Corporate-action sources and successors retain audited existing
  attribution but explicitly lack FIFO pairs rather than invent exchange lots.
- All returned event quantities/notionals and lot amounts are normalized to the
  same selected starting NAV; the UI scales them to illustrative USD 100,000.

## Verification

- Focused Node: 21 passed, including routes, inventory conservation, multiple
  purchases, partial sales, full exit, clipping, negative P&L, corporate actions,
  missing prices, concurrency and fail-closed mismatches.
- Full Node: 1,734 passed, 15 skipped, zero failures.
- Focused Flutter: 21 passed (17 existing + four new EN/ZH desktop/mobile cases).
- `flutter analyze`: no issues. `audit:i18n`: passed.
- Transport/performance regression: 60 passed.
- Production web build passed locally; this is not a production deployment.
- Canonical real-data replay: all-market six windows, S&P 500 six, SEC QQQ
  Nasdaq-100 proxy four. Published daily NAV and every available lot attribution
  reconcile. GOOGL screenshot interval is two matched closed portions; ANET's
  2023–2026 interval has 15 matched closed/open portions with carried-in lots.
- Actual browser: ANET in EN/ZH at desktop and 390×844; closed/open labels,
  opening-basis disclosure, summary and readable mobile rows verified. Viewport
  override reset after checks. Screenshots under
  `/private/tmp/rule-lots-verification/` (not licensed fact exports in Git).

Full Flutter: 608 passed, 32 failed. All 32 failing test names match the preceding
universe release's `flutter-full-final.log`; no added failing names. The four new
dialog cases and all existing rule portfolio widget tests pass. Adjacent legacy
Discover/Research failures were not removed or weakened to obtain a green run.
No canonical storage or database writes were part of this change. Unrelated
worktree changes were preserved. Production acceptance is recorded separately
after publishing and checking the actual runtime; local checks alone do not
establish deployment success.

## Release plan and rollback

This is a code-only release. No database, Fact OS generation, portfolio store,
published strategy NAV or universe snapshot is replaced. Package only the
committed trunk tree in a bounded temporary source archive, leaving unrelated
working-tree edits outside the build.

Verified pre-release rollback targets: AWS `universe-18b8bf6`; Vercel
`dpl_BTiK96ydRiZBSEv5hCkbFAeXgnyd` at
`thesisforge-2kkka1n4l-yudonglu1136s-projects.vercel.app`.
Rollback switches the EB application version and both Vercel aliases together;
it does not restore or overwrite any live user database.

## Production acceptance

- Feature commit `3db689d8fe2d7b9da5337daacf28b8a74b35940e`, pushed to trunk.
- AWS `thesisforge-api-prod`: `intervals-3db689d`, Ready/Green. Code archive
  SHA-256 `2d66ced39ddb6e25e73f3320983e30ec6ced7499180b7bce720d58371e2510ea`.
  Archive inspection: 2,593 entries, no database/private-store/env-secret files;
  only the existing example environment templates are present.
- Vercel `thesisforge`: `dpl_2ARhrsCdfp5dbNR5ND8H9mg494zW`, Ready,
  `thesisforge-2bvybyza5-yudonglu1136s-projects.vercel.app`. Both public aliases
  independently inspected and resolve to this deployment.
- Both domains serve the verified production-auth main.dart.js hash
  `e417bfdaccb146e41eab19fdacef9d8af88b9ae1b645fd0a5bac43e436e9b6e8`.
  Supabase authentication is enabled; developer bypass is false.
- Read-only AWS verification command `813f2ab8-1c14-4dea-9b06-ee5c982bd3c2`
  ran as the actual `webapp` user. All-market six, S&P six and Nasdaq four
  intervals pass v2 checks, including inventories and every supported FIFO lot's
  gross, cost and net reconciliation. Both strategies retain the exact published
  NAV, snapshot identities, 2013/2014 results and disclosed coverage gaps.
  Full host receipt: `/var/tmp/intervals-3db689d-verification.json` (private).
- Signed-in production browser: Chinese desktop and English desktop, and both
  languages at verified 390×844 CSS pixels. ANET and Ackman/NEM dialogs show
  matched sale portions, closing marks, allocated costs and zero reconciliation
  residual. Browser viewport override reset afterward.
- Both domains: unauthenticated investment API is 401, internal API is 404.
  Eight simultaneous health requests return 200 / `ok:true`; the pre-existing
  `stale/degraded` warning for legacy `price_points` dated September 18 remains
  explicit. This code-only release does not claim a market-data refresh.
- Fresh full Fact OS storage audit passed; repository layout retains the same
  11 existing findings. No unrelated data or directories were removed.

Production receipt and screenshots are retained under ignored
`data/releases/rule-trade-intervals-20260924/verification/`. Full Flutter's 32
existing adjacent failures remain disclosed above, not reclassified as passing.
Corporate-action exchange lots remain explicitly unavailable when an audited
FIFO conversion is absent; the existing aggregate attribution remains visible.
