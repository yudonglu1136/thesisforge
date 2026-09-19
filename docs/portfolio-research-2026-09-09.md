# Portfolio × Guru × Valuation — implementation and verification

## Delivery status

Local code and preview only. **Real-account acceptance remains blocked.**
The preview authenticates as `local-dev-user`; it has no access to the user's
production account database. The existing local registry contains only that
development identity. The old page's ISRG allocation is a research decision,
not evidence of the user's broker holdings. No production credentials, holdings
or user databases were copied; no source portfolios were changed or published.

The user was asked whether the existing portfolio is online-only or also
available as a local export. Do not claim the real portfolio is loaded until
the correct authenticated source is available and account-level reconciliation
has passed. Deployment of the broader preview workspace is a separate reviewed
release; the existing production activation gate remains intact.

## What changed

- `PortfolioResearchPanel` replaces the research ledger as the primary book page.
  Overview → Holdings & value → Compare with Gurus; the original research
  allocations, decision journal and shadow configuration remain expandable below.
- New authenticated, private/no-store `GET /api/investment/portfolio-analysis`
  reuses the existing per-user broker loader. It accepts neither an owner ID
  nor an admin account hash from the browser. The development identity cannot
  fall through to the legacy operator/sample portfolio.
- An additive `analysisAccounts` projection preserves per-account IBKR report
  currency, report date, untouched units/prices, explicit report FX and marks.
  It precedes legacy quantity/pence display heuristics and multi-account merges.
  No existing account connection, NAV capture, holding normalization or ledger
  is replaced. Unsupported providers/raw-input gaps return an explicit state.
- Valuation uses the stored PIT model table filtered to the research cutoff.
  No valuation model, guidance, price curve or 13F record is imported/recomputed.
  The current stored sector label is context, not a historical PIT classification.
- Guru comparisons use exact ticker/common-long disclosures with dates, portraits,
  claim-conflict checks and full-book coverage gates. Historical extracts never
  become a renormalized complete book. Click-through preserves manager/accession;
  stock actions open the exact stock's overview or personal valuation worksheet.
- Currency selectors, holding search, incremental 20-row browsing, reload,
  errors, empty/private-source states, cutoff request races, English/Chinese
  and mobile/large text are supported. No hard-coded stock holdings in runtime.

## Metric contract

For each **account base currency separately**:

| Metric | Definition / boundary |
|---|---|
| Net holdings value | Sum of returned reported marks including signed cash and shorts. Null if any mark/currency is unresolved. Not relabelled as broker-reported NAV. |
| NAV reconciliation | Summed holding marks minus separately reported account NAV, only when both are complete. No balancing plug. |
| Positive exposure | Sum of known positive non-cash marks, including uncovered security types. Missing rows disclosed separately. |
| Coverage | Covered long-equity marks / known positive non-cash marks. Uncovered assets are not zero-value assets. |
| Covered model value | Sum of reported shares × published per-share value × explicit report FX. Same quote currency and reconciled units required. |
| Model delta | Covered model value − covered report marks. Not an expected profit or forecast return. |
| Net-value impact | Model delta / positive net holdings value. Null for an unavailable/nonpositive denominator. |
| Revalued + marked remainder | Net holdings value + covered model delta. Everything uncovered remains at its report mark, **not** an independently valued total portfolio. |
| Concentration | Sum repeated ticker exposures within the currency group; top-N / known positive non-cash marks. |
| Sector exposure | Current stored classification, unknown retained, same positive exposure denominator. |
| Stock stress | Uniform −10% / −20% of known long-equity marks. Cash, shorts, options and other assets unchanged; no VaR, probability, correlation or option Greeks. |
| Guru shared-user weight | User's priced long-equity weight in exact matching disclosed stocks. Not evidence of other absent historical holdings. |
| Full-book weight overlap | Σ min(user long-equity weight, Guru common-long weight), only with a complete numeric disclosed book and no claim conflict. |
| Active weight | User long-equity weight − Guru common-long weight; distinct dated books, not a trade instruction. |

Holdings dates and research cutoff are independent and visible: choosing a
historical research cutoff does **not** reconstruct past user ownership.
Published platform models are not the user's personally endorsed assumptions.

Hand-check fixture (test-only): AAA 10×100, BBB 20×50, CCC 5×100, cash 500:
net holdings 3,000; positive non-cash 2,500. AAA FV120 and BBB FV40 produce
covered marks2,000, covered model2,000, 80% coverage, deltas+200/−200, net0.
A −20% equity shock is −500, or −16.667% of net holdings. A complete Guru book
with AAA30%/CCC70% versus user AAA40%/BBB40%/CCC20% has 50% weight overlap.

## Chart contract

Surface: existing Flutter Graphite workspace, not a standalone HTML dashboard.
Ranked horizontal progress bars compare known position/sector exposure on a
fixed 0–100% scale, with exact labels and explicit denominators. Up to six rows
in the overview; detailed positions remain searchable. The existing accent
and neutral palette is retained; signs and values never rely on color alone.
No NAV/return curve is synthesized from insufficient or inaccessible history.
No synthetic fixture is installed in a running preview/API.

## Verification evidence

- 357 full Flutter tests passed (including 14 new focused portfolio tests).
- 84 related backend tests passed (including 22 new analysis/API tests and four
  raw IBKR report-input tests). They use temporary test databases only.
- 41 existing performance regression tests passed.
- Analyzer and bilingual audit passed; release build succeeded.
- Synthetic integration input joined against actual local public PIT/Guru data:
  one eligible equity model, 27 dated Guru books, 1,369ms local read and zero DB
  writes. This is **not** a real-account benchmark or production latency claim.
- Browser verifies actual account-required state and preserved research ledger.
  Authenticated populated layout/flows are fixture-tested, not live-account
  browser-verified. EN/ZH phone screenshots and desktop state are in
  `output/portfolio-research-20260909/`.
- Relevant logs: `/tmp/tf-portfolio-all-tests.log`,
  `/tmp/tf-portfolio-widget-tests-final.log`, `/tmp/tf-portfolio-server-tests.log`,
  `/tmp/tf-portfolio-performance-tests.log`, `/tmp/tf-portfolio-analyze.log` and
  `/tmp/tf-portfolio-build-final.log`.

## Remaining acceptance

With the user's correct account source: verify account count, original report
units/currency/date, cash, sum of positions versus broker NAV, valuation coverage,
whole-book contributions and Guru drill-downs in the browser. Do not publish
the development-auth build or use an arbitrary user's account to fill the page.
