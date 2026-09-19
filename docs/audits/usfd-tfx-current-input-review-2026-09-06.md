# USFD / TFX current-input review

Reviewed 2026-09-06; source cutoff 2026-09-05. Private candidates only. This does not approve historical PIT curves, mutate a database, or authorize release. No market price is a valuation input.

## Reproducible artifacts

- Original filing extractor: `scripts/build-usfd-tfx-source-review.py` (22 original 2024–2026 10-K/10-Q filings).
- Current candidate generator: `scripts/build-usfd-tfx-current-review.py`.
- Tests: `python3 -m unittest scripts/test_usfd_tfx_current_review.py` — 9 passed.
- Private evidence: `output/guru-valuation-expansion-2026-09-05/usfd-tfx-evidence-review-20260906/evidence.json`; SHA256 `d8869a3cab82f333dd2a6e2e9e18d9fb77c50404028745177eacd83893ff0b52`.
- Current candidate v2: `output/guru-valuation-expansion-2026-09-05/usfd-tfx-current-review-v2-20260906/usfd-tfx-current-review-candidates.json`; SHA256 `0a4e7b34cc01c40669af40a8e60ac48eda9d2df922e55cb6686db2c56ff852df`.
- Every source in the candidate has its exact URL, publication date, period, local original bytes, locator and SHA256. Original provider payloads and payload hashes are preserved. Same-period conflicting facts fail; annual plus current YTD minus prior YTD is explicit.

Generate into a **new** output directory:

```sh
python3 scripts/build-usfd-tfx-current-review.py \
  --evidence output/guru-valuation-expansion-2026-09-05/usfd-tfx-evidence-review-20260906/evidence.json \
  --official-cache output/guru-valuation-expansion-2026-09-05/official-sec-cache \
  --output-dir output/guru-valuation-expansion-2026-09-05/usfd-tfx-current-review-NEW
```

## USFD: current-only FCFE scenario can be reviewed independently

USD millions. The dedicated annual lease cash table is preferred to conflicting MD&A, but the conflict is retained, not deleted.

| Cash input | FY2025 | H1 2026 | H1 2025 subtracted | TTM |
| --- | ---: | ---: | ---: | ---: |
| Reported CFO | 1,369 | 725 | 725 | 1,369 |
| Cash PPE purchases | 410 | 174 | 161 | 423 |
| Recurring SBC allowance | 83 | 54 | 45 | 92 |
| Finance-lease cash principal | 120 | 63 | 77 | 106 |

Sources: [FY2025 original 10-K](https://www.sec.gov/Archives/edgar/data/1665918/000166591826000008/usfd-20251227.htm), [H1 2026 original 10-Q](https://www.sec.gov/Archives/edgar/data/1665918/000166591826000045/usfd-20260627.htm), [H1 2025 original 10-Q](https://www.sec.gov/Archives/edgar/data/1665918/000166591825000127/usfd-20250628.htm).

`1,369 − 423 − 92 − 106 = 748m`; optional analyst reconciliation reserve `20m` gives `728m`.

Two real source discrepancies remain explicitly quantified:

1. FY2025 audited lease note reports 120m cash principal; MD&A says 110m scheduled lease payments. The dedicated note wins. No additive 10m second reserve is imposed after already using 120m.
2. H1 2025 MD&A reports 77m. Financing cash and the debt note imply approximately 57m: `4,303 principal payments − 4,069 new borrowings − 177 funded-principal reduction = 57`. The latter is an analyst reconstruction from million-rounded balances, not separately reported cash. Its 20m gap is an **optional extra TTM cash reserve**, never relabeled as actual expense.

An additional provider-source correction is material to audit accuracy even if small economically: provider TTM capex is 421m, whereas official `410 + 174 − 161 = 423m`. Thus the initially discussed 750/730m diagnostic becomes source-corrected **748/728m**. No tolerance was used to hide the difference.

Quoted-security denominator: **216.3m ordinary shares at June 27**, disclosed to 0.1m precision, rather than later cover count 216.330723m. FY2025 options are 1.304833m, all vested/exercisable, weighted strike $26.55, with zero remaining service cost. The current interim count is not separately reported; the candidate shows zero versus full delivery of those legacy options, with no exercise proceeds, as an explicit stress—not an exact current diluted share claim.

Debt diagnostic: provider debt 5,405m includes noncurrent operating leases 168m. Official debt including finance leases is 5,237m; finance leases are 591m. Since this is after-interest FCFE and lease cash is deducted once, there is **no further net-debt or operating-lease deduction**, no cash addition, no dividend addition and no buyback premium.

Management's [Aug6 outlook](https://www.sec.gov/Archives/edgar/data/1665918/000166591826000043/usfd06272026ex991.htm) is sales growth 4–6%, adjusted EBITDA growth 9–13%, adjusted EPS growth 18–24%; the 10-Q cash-capex outlook is 400–440m. These are not FCFE forecasts. Current candidate cash-growth/Ke/g assumptions are labeled analyst estimates.

Diagnostic only, five rolling forecast years with year-end discounting:

| Analyst scenario | Cash-growth path | Ke / g | Value range including reserve and legacy-option stress |
| --- | --- | --- | ---: |
| Bear | 2%, 2%, 2%, 2%, 2% | 11% / 2% | $37.92–39.19 |
| Base | 8%, 7%, 6%, 4%, 3% | 10% / 2.5% | $52.45–54.21 |
| Bull | 12%, 10%, 8%, 6%, 4% | 9% / 2.5% | $67.17–69.43 |

Base terminal share is 71.0%. These are not asserted CAPM estimates or observed peer prices. Parent/root must independently review implementation and scenario semantics before activation. All historical curves remain unapproved by this artifact.

## TFX: correct the continuing-business input before choosing valuation

The original [FY2025 10-K](https://www.sec.gov/Archives/edgar/data/96943/000009694326000019/tfx-20251231.htm) and [H1 2026 10-Q](https://www.sec.gov/Archives/edgar/data/96943/000009694326000095/tfx-20260630.htm) explicitly split continuing and discontinued operations. The standalone current bridge is:

| Continuing cash input, USD m | FY2025 | H1 2026 | H1 2025 subtracted | TTM |
| --- | ---: | ---: | ---: | ---: |
| CFO | 96.682 | 138.559 | −9.296 | 244.537 |
| Cash PPE purchases | 95.236 | 32.825 | 51.921 | 76.140 |
| SBC | 25.695 | 12.182 | 12.287 | 25.590 |

Source-reconciled continuing cash diagnostic: `244.537 − 76.140 − 25.590 = 142.807m`.

Provider TTM CFO403.196/capex63.422/FCF339.774 cannot simply flow into a continuing-business model. Official continuing CFO is **158.659m lower** and continuing capex **12.718m higher**. Q2 total NI99.693 includes discontinued NI57.931; continuing NI is **41.762m**. Period-end common shares are `(48.203 issued − 5.831 treasury) = 42.372m`, at thousand-share precision.

The 142.807m is **not** yet normalized recurring FCFE: the April patent-litigation settlement generated a one-time 25m cash receipt. Full-cash removal gives 117.807m; a separately labeled 23% analyst tax-effect estimate gives 123.557m. The actual cash tax attributed to this receipt is not disclosed. Do not capitalize the litigation receipt perpetually.

Visible statement labels matter: in the H1 filing, some inline tags are mismatched. The 64.540m visible balance-sheet row is noncurrent **operating leases**, while the correctly reviewed fair-value note acquisition-contingency liability is **47.412m**. A parser that trusts the tag name alone will assign the wrong claim. Current funded debt is `87.500 + 2,720.509 = 2,808.009m`; provider2,872.549 adds the 64.540 operating leases. Cash300.159 excludes restricted16.760 and discontinued47.368.

### Dated transaction bridge is now sourced, not a missing-data excuse

[Aug5 OEM pro forma filing](https://www.sec.gov/Archives/edgar/data/96943/000009694326000087/ex991to8-5x2026reoemprofor.htm): sale cash1,500m; estimated tax236.4m; transaction costs18.8m; reported after-tax proceeds approximately1,244.9m. Mandatory term-loan repayment700m leaves the precise reported pro forma cash increment **544.873m**. The rounded text sums differ by0.1m; preserve disclosed precision rather than inventing a tie.

The same pro forma assumes recurring interest savings28m pretax /21.560m after tax from retiring700m at4%. Applying this separately to the litigation-normalized cash range gives **139.367–145.117m**, before other underwriting choices. Temporary transition-agreement annual after-tax income6.783m is based on agreements lasting up to24 months and must not enter perpetuity.

Unsold Acute Care/IU has contractual **530m gross** consideration, expected Q4 closing with conditions. Do not claim a whole-company result while silently assigning it zero. A transparent zero-to-contract-gross sensitivity is possible, but 530m is not net after-tax cash.

[Aug7 ASR disclosure](https://www.sec.gov/Archives/edgar/data/96943/000009694326000097/tfx-20260807.htm):250m payment scheduled Aug10; initial delivery equals80% of cash based on Aug6 close; final shares depend on VWAP through settlement. Do not combine post-ASR cash with pre-ASR shares and call the result exact. A pre-ASR **Aug6 snapshot** can be date-valid; a Sept5 current scenario must reconcile the known cash action and actual share observation or display a clearly labeled range.

Latest [management guidance](https://www.sec.gov/Archives/edgar/data/96943/000009694326000091/ex991to8-6x2026req2earning.htm): continuing GAAP revenue2,260–2,280m, GAAP EPS2.54–2.84, adjusted EPS6.90–7.20. Adjusted EPS is not FCFE and includes adjustments that need separate judgment. Transaction/award claims and recurring cash normalization remain root model-review items; the evidence permits an auditable current scenario, not blanket historical approval.
