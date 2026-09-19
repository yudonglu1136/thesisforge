# TBBB current-only model: independent source and snapshot audit

Review date: 2026-09-06. Information cutoff and valuation date: **2026-09-05**.
Financial period: 2026-Q2 / 2026-06-30. No production writes, deployment,
default-universe change, or historical economic-model approval.

## Conclusion

**Pass for current-only source/arithmetic candidate; caution for economic assumptions;
release remains subject to the parent pipeline's independent gates.**

The pre-existing TBBB model was already runnable. This work adds immutable source
bindings, independently recomputed source rows and valuation arithmetic, mutation
tests, and a pure normal-snapshot adapter. It does not replace uncertain inputs
with invented reported facts or create a historical curve.

| Scenario | USD per maximum current claim | Funding deficit, MXN m | Interpretation |
|---|---:|---:|---|
| Conservative baseline | 5.5527443521 | 0 | Conditional full-share-claim FCFE scenario |
| Historical-margin recovery | 7.8520975476 | 0 | Anchored alternative, not a confidence bound |
| Financing/cash-conversion stress | **null** | 3,825.029369 | Path requires financing; not a publishable price target |

The stress's mechanical result is approximately USD 0.365866, retained only inside
its qualified calculation details. Negative operating value makes its terminal
share invalid. It must not appear as an ordinary downside target.

## Audited bridge

Amounts below are MXN million. TTM is FY2025 + H1 2026 - H1 2025 from the dated
annual filing/current comparative statements, not a sum of mixed cumulative quarters.

| Component | TTM | Treatment |
|---|---:|---|
| CFO | 7,011.837 | Reported operating cash |
| Net cash PPE investment | (3,772.646) | Preserve comparator inconsistency, no zero floor |
| Software/intangible investment | (27.855) | Cash investing outflow |
| Lease principal | (885.754) | Financing-classified under IFRS; deduct once |
| Lease interest | (1,637.335) | Financing-classified; deduct once |
| Other debt cash interest | (110.792) | Deduct once |
| Intermediate economic cash bridge | **577.455** | Not automatically a normalized FCFE forecast |

The model then forecasts investment, working capital, debt principal and operating
cash reserve explicitly. Supplier invoices already reduce CFO when the bank pays;
gross supplier-finance repayment is not another operating expense. H1 actual net
cash borrowing is MXN -629.615m and is retained once in the annual/H1 bridge.

Shares: June issued A 77,938,244 + B 5,210,000 + C 38,039,530 = 121,187,774.
Add conditional LEP 4,374,993, Bolton delivery 4,224,960, post-IPO RSUs 535,664,
legacy options 37,640,312 and post-IPO options 4,082,500. Subtract verified August
withheld shares 26,515: **172,019,688 maximum current claims**. All classes have
pari-passu economic distribution rights. This is neither public float nor an
assertion of September basic shares. No exercise cash is credited. Current awards
and future grants are not also deducted as cash SBC. Future gross award dilution
uses FY2025's 3,401,000 new awards as an explicit analyst assumption.

Legacy promissory/convertible notes were repaid in 2024. Future authorization to
issue preferred shares is a governance risk, not an outstanding preferred balance.
Current equity statement/rights review did not identify a separate outstanding
preferred or NCI claim. Cash payments servicing financed equipment remain in the
forecast; no second lease-debt deduction is made after FCFE valuation.

## Management evidence and economic judgments

March 11, 2026 management FY2026 total revenue growth guidance is 29%-32%; not
claimed reaffirmed in Q2. Its 25% maximum weighted use is bounded to +/-15 percentage
points around the financial trend. Seven valid YoY observations in the latest
eight-quarter window give 35.06348977% median; 2024-Q3 has no positive like-for-like
comparator and is explicitly omitted, not filled. All 14 current/comparative
revenue observations are now corroborated to exact official rows. This establishes
current-date numerical corroboration, not original provider datekey provenance or
economic approval of those historical nodes.

FY2026 MXN 5,250m budget is mixed cash/noncash investment, not cash-capex guidance.
The model's allocation of unclassified MXN 1,205m as recurring capital and its cash
financing fraction are analyst estimates. Cash profit before working capital and
capex but after taxes/all lease service uses reported aggregate margins. Continued
negative-working-capital funding, equipment financing and future awards are
explicit sensitivities, not management promises.

Base USD Ke = (4.78%-0.23%) + 1.0 x 4.23% + 2.46% + 1.00% = **12.24%**.
MXN nominal Ke = (1.1224 x 1.03 / 1.02)-1 = **13.34039216%**.
September 4 ECB MXN/EUR 19.6401 divided by USD/EUR 1.1622 gives
**16.8990707279 MXN/USD**. Inflation parity is an analyst long-run FX convention,
not an observed FX forward. USD 236m reported rounded bank deposits stay in USD;
operating MXN cash is separately reserved. No deposit interest is credited.

Year-end timing: 117/365-year stub to December 31, 2026, then five annual forecast
payments. Forecasts are not historical chart points. Company terminal growth is
MXN 3%; continuing awards reduce per-current-claim growth to approximately 1%.
Base terminal PV is 64.2121% of operating value.

Two disclosed source precision discrepancies are preserved:

- The FY/H1 PPE-disposal combination is negative MXN 0.363m. It affects the
  diagnostic bridge but does not set the forward capital budget.
- FY2024 other-assets working-capital change is 418.647m in the March earnings
  release versus 418.646m in the April annual report. The chosen March scenario
  source is retained explicitly, not silently overwritten.

## Artifacts and deterministic replay

Private root: `output/guru-valuation-expansion-2026-09-05/tbbb-independent-review-v2-20260906/`.

- `tbbb-source-bindings.json`: **26** source documents plus config/SEC index byte
  bindings. SHA256 `d9fb2f48c6bb4c26dadb0871350b64931620c6d7bb3524d999bba9ff2d8f8dcb`.
- `tbbb-source-facts.json`: **36** financial metric observations, **19** statement/
  guidance/claim passages, **3** macro records, **14** growth revenue observations.
  SHA256 `2176dfa14d4f797a598b3a3248843fa74efe14015821588d28c51f3fe9f3cef9`.
- `tbbb-current-model-candidate.json`: independent source and three-scenario replay.
  SHA256 `893e7840312b6fb228dd30c099c25a87d19d726ced66e5374c80c3345aca7274`.
- `tbbb-current-snapshot-candidate.json`: one normal ticker snapshot/valuation
  row/model run, no quote supplied. SHA256
  `d7763347240b031199cb962cf53365af0324fcd5183e0a1588feaf7d0c8bfa6e`.
- `tbbb-current-snapshot-replay.json`: independently rerun renderer, byte-identical
  SHA256 to the preceding snapshot.

Exact source hashes and SEC accession/filing/acceptance fields are checked from the
original submission index. After-hours SEC acceptance may precede the next-business-
day filed date; these two fields are bound separately, not forced to the same date.
Macro download timestamps are not confused with September 4 observation dates.

```sh
node scripts/render-tbbb-current-snapshot.mjs \
  --candidate output/guru-valuation-expansion-2026-09-05/tbbb-independent-review-v2-20260906/tbbb-current-model-candidate.json \
  --candidate-sha256 893e7840312b6fb228dd30c099c25a87d19d726ced66e5374c80c3345aca7274 \
  --output /an/explicit/new/tbbb-snapshot.json
```

Never use a pre-existing output path; replay tools refuse overwrite. `--input` and
`--output` on `evaluate-tbbb-underwritten.mjs` permit pure saved-JSON replay without
database/network imports. Recreate source review using `build-tbbb-source-binding.py`
then `review-tbbb-bound-source-facts.py`, each into explicit new private paths.

## Adapter contract and price exclusion

`buildTbbbCurrentSnapshotCandidate` in `server/tbbbCurrentSnapshot.js` requires
original saved input, source-bundle JSON, source-review JSON, and separately trusted
input/source/model digests. It re-runs the model and independent audits. It returns
normal `latest`, one `history` row, `scenarios`, `dataQuality`, `methodCards`, typed
cash/share/FX details, EN+ZH warnings, plus a private `valuationRows`/`modelRuns`
envelope. `historicalCurveAuthorized=false` and `releaseReady=false` remain explicit.

No quote is fabricated. Optional comparison-price evidence uses the existing
`valuationComparisonPrice.js` exact registry and resolver; Sharadar paid close only,
TBBB/USD, source field `close`, `currency_per_share`, cutoff 2026-09-05. It requires
an `original_vendor` record and exact original `ticker/date/close/currency` fields,
its SHA256, plus a separately pinned digest of the complete comparison request.
Conflicting same-provider rows fail. Unverified source labels, adjustment fields,
future prices or substitute symbols fail. The optional CLI pair is
`--comparison-price` / `--comparison-price-sha256` (canonical JSON digest).

Snapshot upside uses **ratio** units: 0.10 means 10%, matching `buildValuationRows`,
`updateTickerSnapshot`, LSEG overlay and Flutter renderers. It is not multiplied
by 100 before storage. Comparison-price changes alter only quote/upside fields,
not cash flows, claims, DCF, model inputs or scenario details.

## Tests and release boundary

**96 JS tests pass**, including existing TBBB model tests, new independent audit,
normal-snapshot adapter and shared comparison-price tests. **6 Python source-row
tests pass**. Covered: units; exact row/period/hash; currency inversion; historical
misuse; duplicated leases/SBC/supplier finance; omitted C shares; market-priced
treasury-stock illustration misuse; terminal year/stub; funding-gap target exposure;
model self-approval; source-byte alteration; same-series price conflict; quote-only
metamorphism; upside ratio units; deterministic non-mutating replay.

The model-audit skill drove separate source, accounting, scenario and arithmetic
checks. The PDF reading workflow verified the Banxico forecast table visually;
its published English translation states that the Spanish original controls.

Remaining work is platform integration and the root release gate, including a
real separately audited paid comparison quote if desired. This candidate does not
authorize generic TBBB history, a statistical price interval, exact option valuation,
an unconditional financing forecast, production deployment, or any unrelated issuer.
