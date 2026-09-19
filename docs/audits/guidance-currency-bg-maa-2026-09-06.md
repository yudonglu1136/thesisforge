# Historical guidance currency — BG15 + MAA1

## Conclusion

Currency-only QA passes for this bounded batch: 16 original guidance events
were enriched on a new private source copy, and all 50 accumulated event-level
currency contracts pass independent validation. Full-source/model release remains
**blocked**. Currency evidence does not approve a forecast's number, economic
owner, scope, consumption, or valuation.

The filing-review and model-audit workflows guided the original-file,
issuer-continuity and EPS-versus-million-unit checks. No production, default
universe, financial amount, forecast scalar, issuer-review status or model was
changed by this batch.

## Original proof

| Events | Original issuer and evidence | Date treatment |
|---|---|---|
| BG: 13 before redomestication | Bunge Limited, CIK 0001144519; original 10-K expressly states USD reporting currency | Latest retained original 10-K already filed before each event; maximum 400 days old |
| BG: 2 on 2024-02-07 | Bunge Global SA, CIK 0001996862; consolidated income and balance-sheet captions explicitly state US$ | Same-day original official release; also records the 2023-11-01 Bermuda-to-Switzerland share-for-share continuation |
| MAA: 1 on 2019-05-02 | Mid-America Apartment Communities, CIK 0000912595; original 2018 10-K XBRL uses USD and USD/shares | 10-K filed 2019-02-21, before the May earnings call; no later 10-Q used |

Bunge's current source is its [2024-02-07 official earnings
release](https://www.sec.gov/Archives/edgar/data/1996862/000199686224000002/epr12312023.htm).
Predecessor and current CIKs are separated at the actual 2023-11-01 effective
date; no current reporting currency is projected backward through a later filing.

MAA's [2018 original 10-K](https://www.sec.gov/Archives/edgar/data/912595/000091259519000015/maa12312018-10k.htm)
and its [original XBRL instance](https://www.sec.gov/Archives/edgar/data/912595/000091259519000015/maa-20181231.xml)
contain the exact parent-company reporting contexts. Aggregate Assets, Revenues,
operating cash and diluted EPS use USD / USD-per-share units. The independently
verified contexts have only `srt:ConsolidatedEntitiesAxis = srt:ParentCompanyMember`;
LP and business-segment contexts cannot substitute. The aggregate CompanyFacts
API did not provide current 2019 evidence, so its stale 2014 result was rejected
and the original filing instance was inspected directly.

MAA's [official quarterly release](https://www.sec.gov/Archives/edgar/data/912595/000091259519000022/a1q19exh991.htm)
also corroborates the original 2.19–2.43/ share range and 2.31 midpoint. Its bare
dollar symbol alone was not the USD evidence.

## Quantified result and preservation

On the same current independent checker, before and after:

| Audit item | Before | After |
|---|---:|---:|
| Currency review incomplete | 69 | 53 |
| Quantified-evidence review incomplete | 381 | 381 |
| Semantic classification conflicts | 172 | 172 |
| Other coverage-summary findings | 2 | 2 |
| Missing / incomplete issuer coverage | 0 / 0 | 0 / 0 |
| Source event count | 86,510 | 86,510 |

All non-target rows and all financial rows are exact. The only changed fields
are SQL currency and the payload's currency, currency-resolution metadata and
typed official-currency evidence. The 14 EPS events retain null monetary-million
amounts and their original per-share scalar; EPS is never stored as `amountM`.
No original quote, CIK in financial data, growth basis, amount, fiscal scope,
source owner or economic-review approval was changed.

Known separate issue: BG event `dd95e7501f1f02307cf0b918` on 2019-05-08 stores
CapEx 300m although its original CapEx clause says 550m; 300m belongs to the later
net-interest range. That amount was intentionally not changed by this currency
batch. The current aggregate source checker does not report that owner error;
the parser/owner repair lane has received it, and it must not be treated as
economically approved merely because currency now passes.

## Private reproducible artifacts

All filenames below are in `output/guru-valuation-expansion-2026-09-05/`:

- Input: `additive-full-rebuild-v30-four-20260906/source-v31b-currency34.sqlite`,
  SHA `e6d1d7d936dc64381e5a150891f4c7cb0fde695ad3621ab8314a583176ae8443`.
- Candidate: `currency-lane-source-v31b-currency50-20260906.sqlite`,
  SHA `e5a6be81233aefe9eea26da3d54edd2d3ab1c12ac48d28668dfe145900378c04`.
- Exact 16-event ledger: `currency-lane-bg15-maa1-ledger-20260906.json`.
- Copy-only preservation audit: `currency-lane-reviewed50-apply-20260906.json`.
- Before / after full-source audits:
  `currency-lane-v35-before-full-source-audit-20260906.json` and
  `currency-lane-v35-after-full-source-audit-20260906.json`.
- All original 69 unresolved events grouped by ticker/date:
  `currency-lane-v35-remaining69-20260906.json`.
- Updated registry: `currency-lane-reviewed50-registry-20260906.json`,
  SHA `68d6bf9206c0f064eec28716f9b53e96c7885e6c7ce34254ecd28d78e7a15970`;
  exact additions are retained in the tracked reviewed-document registry.

Remaining currency clusters: DIS14, XYZ8, CI7, ABBV4, CSGP3, FERG3, ARM2,
AVAV2, ICE2, PSKY2, APA1, GEV1, LIN1, NWSA1, Q1, TSLA1. XYZ remains blocked;
USD-denominated revenue and limited operating FX exposure do not by themselves
establish the consolidated presentation currency.

## Tests

108 Python and 19 Node tests pass in the combined lane regression. The new
cases cover null/missing EPS scalars, EPS-versus-millions, wrong issuer/date,
changed original file/fragment hashes, CAD substitution, LP/segment context
substitution, invalid period and duplicate facts. The independent XML oracle
also rejects semantic tampering when test fixtures recompute fragment hashes.
These are source-evidence tests, not final two-run model-release verification.

## Strict binding to the v32 source replay

The currency implementation is frozen. A separate read-only helper,
`scripts/rebind-bg-maa-currency-ledger-v32.py`, compared every SQL column and
every parsed payload property of all 16 events against
`source-v32-currency34-crdo-replayed.sqlite` (SHA
`aa99ea86219b4e08ffdb85415f7ca45badc22efc66541f3d5bc5dbfe65036a4d`).
All 16 differ only in the exact reviewed `extraction_version` transition from
v31b to v32, both in SQL and JSON. No numerical, owner, scope, quote, review,
currency or other payload field changed. Missing null properties and newly
introduced properties would be conflicts; they are not silently dropped.

The new ledger is
`currency-lane-bg15-maa1-ledger-v32-bound-20260906.json`, SHA
`3a9960f0d6b764f149caa217adee2702dc71551ebef6b8cc03ece23bb0a58025`.
Each `originalPayloadSha256` now binds the actual v32 raw payload, while the
prior payload hash and full comparison evidence remain attached. The detailed
report is `currency-lane-bg15-maa1-rebinding-v32-report-20260906.json`.
Both source files were opened read-only and their complete hashes were checked
before and after; no rows were changed or currency evidence applied in this
rebinding step. Five additional tests pass, including economic/quote/review
conflicts, unknown extraction versions, incorrect prior hashes, missing/extra
schema properties, JSON duplicates and non-finite numbers.

The BG 300m/550m ownership defect remains separately blocking. This exact
version-only binding does not approve that amount. If a subsequent replay
corrects its amount, this narrow version-only helper must reject that event;
the corrected event requires a newly reviewed economic binding.
