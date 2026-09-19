# Official guidance and Diageo currency repair

Input-only audit. No model release, commit or deployment is authorized by this report.

## Delivered private source

`output/guru-valuation-expansion-2026-09-05/official-coverage-repair-bae-dge-v2-20260906.sqlite`

This is derived from `full-reviewed-source-v26.sqlite`. It is **not** the latest transcript replay. Merge only these source-owned changes into the latest full source:

- Official guidance rows and coverage for BA.L, BF.B, BRK.B, CCEP, DGE.L, ED, ERIE, EXPD, FER, NVR, SPCX and VMRK. Do not replace their transcript-owned rows.
- Twelve DGE.L financial rows: ARQ and ART for 2024-Q2, 2024-Q4, 2025-Q2, 2025-Q4, 2026-Q2 and 2026-Q4.
- Scoped official-import metadata and `bae_official_guidance_column_replay` (the latter archives the superseded original BAE quotations verbatim).

All eleven SEC issuers were reviewed from 2026-01-01 through 2026-09-05. This is not a claim of a new full-history SEC filing review. Earlier official evidence is retained. BAE used the dated 2026-07-30 primary release plus deterministic current-column replay of the already-persisted 2025-07-30 original table quotation.

## Diageo: substantive source currency defect

Diageo began reporting in USD from FY24 while its London ordinary shares remained GBP quoted. The previous source path labelled native USD amounts as GBP with a conversion scale of 1. FY23 original GBP observations must remain unchanged: later USD comparative recasts were not visible then.

Primary evidence: [FY24 interim SEC filing](https://www.sec.gov/Archives/edgar/data/835403/000165495424001045/diageoplc2902b.htm), [issuer explanation of the currency change](https://www.diageo.com/en/news-and-media/press-releases/2024/diageo-plc-publishes-recast-us-dollar-financial-information), and [FY25 official results](https://www.diageo.com/en/news-and-media/press-releases/2025/2025-preliminary-results-year-ended-30-june-2025).

| Period | Retained PIT date | GBP per USD | Native revenue, USD m | Correct revenue, GBP m | Native FCF, USD m | Correct FCF, GBP m |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2024-Q2 | 2024-01-30 | 0.789489213 | 20,397 | 16,103.211 | unavailable | unavailable |
| 2024-Q4 | 2024-08-01 | 0.781610900 | 20,269 | 15,842.471 | 2,609 | 2,039.223 |
| 2025-Q2 | 2025-02-04 | 0.804915336 | 20,208 | 16,265.729 | 2,734 | 2,200.639 |
| 2025-Q4 | 2025-08-14 | 0.736526946 | 20,245 | 14,910.988 | 2,748 | 2,023.976 |
| 2026-Q2 | 2026-02-25 | 0.739477257 | 19,804 | 14,644.608 | 2,584 | 1,910.809 |
| 2026-Q4 | 2026-08-18 | 0.739331375 | 19,643 | 14,522.686 | 3,211 | 2,373.993 |

Every monetary field was reconciled against the exact dated DEO paid-provider parquet row before conversion. The independent check reconstructs each GBP amount from the stored USD and GBP ECB reference observations, not from the builder's returned conversion scalar. Formula: native USD × GBP units per EUR ÷ USD units per EUR. Shares never receive FX or the DEO ADR factor.

SQL preservation checks: exactly twelve financial rows changed; unrelated/pre-FY24 financial differences zero; all share-count differences zero. DGE's 2026 official refresh then passed with 24 evidence rows, nine usable, fifteen research-only, zero unresolved currency and zero access failures.

Machine-readable evidence: `output/guru-valuation-expansion-2026-09-05/dge-dated-currency-repair-20260906.json`.

## BAE: current guidance column ownership

The old 2025 table parser took prior actual revenue £28,335m and EBIT £3,015m from the Results column. The replacement projects only the explicitly labelled Updated guidance column and retains previous guidance/results in full raw-table provenance.

The [2026-07-30 primary release](https://www.baesystems.com/en-sa/article/2026-half-year-results) yields sales growth 8–10%, underlying EBIT growth 10–12%, EPS growth 11–13%, and annual FCF **greater than** £2.0bn. The latter is a floor, not an expected midpoint. Cumulative 2024–2026 FCF above £6.7bn remains multi-year research and cannot be annualized. The primary disclosure refers to BAE's underlying/alternative performance measures, not a separately verified IFRS sales bridge.

2025 current-column replay yields sales growth 8–10%, EBIT growth 9–11%, EPS growth 8–10%, and annual FCF floor £1.1bn. No BAE financial amounts were edited. Original superseded quotations are archived in both source metadata and `bae-guidance-replay-v2-20260906.json`.

## Verification and remaining work

The lane's five Python test modules pass **78 tests**. They cover bounded actual-listed SEC HTML fallback, additive preservation, BAE column selection and cumulative exclusions, DGE dated currency/ordinary shares, and independent native/GBP reconciliation.

All twelve coverage records now have permitted statuses: eight covered official issuers, four reviewed no-quantified issuers. However the independent source-only audit still flags **30 older retained official extraction issues**: BA.L six, BF.B fifteen, ED two, EXPD one, VMRK six. Coverage is not release approval. Detailed source IDs/reasons: `official-12-source-audit-20260906.json`.

The latest BAE projected rows and corrected DGE rows have no findings in that scoped independent source audit. Full current-source replay, all-issuer economic checks, deterministic model rebuilds and the unchanged full release verifier remain mandatory before any deployment.
