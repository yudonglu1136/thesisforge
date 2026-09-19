# DIS / legacy Cigna dated statement-currency repair

QA status: **18 currency repairs pass; full source and model release remain blocked**.

This batch used the filing/QoE review and model-audit workflows to establish
consolidated issuer ownership, point-in-time availability and statement units.
It did not approve guidance amounts, target years or economic model consumption.
The batch is frozen at 18 events (DIS 14, legacy Cigna 4); no production database,
financial row, Guru holding, model value or review approval was changed.

## Exact inputs and outputs

All paths below are relative to `output/guru-valuation-expansion-2026-09-05/`.

| Artifact | Path | SHA-256 |
|---|---|---|
| Protected input | `additive-full-rebuild-v30-four-20260906/source-v32-currency52-protected25.sqlite` | `1af2bb4f0f5e67982bd98eb5b5bc0c7063f51a33a1c122504bf7f6d7eae2616e` |
| Currency-70 candidate | `currency-lane-source-v32-currency70-20260906.sqlite` | `528fa292ba9a9a3e934aa02f8afd1217cdd47439e2cd5ce21a099ea2f0ebd55c` |
| Currency-70 registry | `currency-lane-currency70-registry-20260906.json` | `8b15a36a5d4a7302279b9df7e4e4b0a83ca8ee1e6506da8aac502930d96d3d8e` |
| Reviewed 18-event ledger | `currency-lane-dis14-ci4-statement-ledger-20260906.json` | `db4c121045b54d4c97c61f10f0a3878b532e53348ce62fce496408e32611f179` |

Before applying, every column and the raw payload bytes of all 18 target rows
were compared with the previously reviewed currency-52 source: **18/18 exact**.
The protected-25 replay did not overlap these rows; no version-only rebinding was
needed. The protected input's full hash was checked again after all operations
and remained unchanged.

`currency-lane-currency70-apply-20260906.json` records the exact 18-event change
list, original quotation hashes and before/after payload hashes. Only these
fields changed: SQL `currency`, payload `currency`, `currency_resolution` and
`official_guidance_currency_evidence`. Every unrelated source row, financial row
and existing 52 registry entry is exact. Original identity, source owner, quote,
amount, per-share value, metric, dates and review states are preserved.

## Primary evidence and independent checks

Nine original SEC annual filings supply the 18 proofs. The contract requires a
parent consolidated income-statement caption plus original, CIK-matched,
whole-entity XBRL contexts with no segment or scenario. It checks four aggregate
facts: assets, revenue, operating cash flow and diluted EPS. Monetary units must
be USD and EPS must be USD/share. This is not a first-unit-in-the-file inference:
other units elsewhere in these documents remain untouched.

| Issuer / events | Filed date / fiscal period | Original annual filing |
|---|---|---|
| CI / 4 | 2018-02-28 / 2017-12-31 | [Cigna 2017 10-K](https://www.sec.gov/Archives/edgar/data/701221/000104746918001158/a2234149z10-k.htm) |
| DIS / 3 | 2010-11-24 / 2010-10-02 | [Disney 2010 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000119312510268910/d10k.htm) |
| DIS / 2 | 2011-11-23 / 2011-10-01 | [Disney 2011 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000119312511321340/d232174d10k.htm) |
| DIS / 1 | 2012-11-21 / 2012-09-29 | [Disney 2012 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000119312512479027/d405160d10k.htm) |
| DIS / 2 | 2013-11-20 / 2013-09-28 | [Disney 2013 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000100103913000164/fy2013_q4x10k.htm) |
| DIS / 1 | 2014-11-19 / 2014-09-27 | [Disney 2014 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000100103914000228/fy2014_q4x10k.htm) |
| DIS / 2 | 2016-11-23 / 2016-10-01 | [Disney 2016 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000100103916000516/fy2016_q4x10k.htm) |
| DIS / 2 | 2017-11-22 / 2017-09-30 | [Disney 2017 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000100103917000198/fy2017_q4x10k.htm) |
| DIS / 1 | 2018-11-21 / 2018-09-29 | [Disney 2018 10-K](https://www.sec.gov/Archives/edgar/data/1001039/000100103918000187/fy2018_q4x10k.htm) |

All original HTML, filing indexes and full original XBRL bytes are retained in
`currency-lane-dis-ci-abbv-primary-20260906/`. The typed proof preserves eight
verbatim XBRL fragments, their hashes and original root namespace. Python and
independent JavaScript validation reconstruct the contexts, units and facts,
verify original filing date/CIK/accession/form, and reject conflicting duplicate
facts. The full-original independent check passed **18/18**; all **70 actual
typed contracts** on the output database pass independently, with zero failures.

The exact legacy-issuer contract does not extend old Cigna CIK 0000701221 to
events on or after 2018-12-20, nor old Disney CIK 0001001039 to events on or after
2019-03-20. These are not generic approvals of parent-only or subsidiary units.

## Same-checker full-source comparison

Both audits use the same current `audit-staged-guru-guidance.mjs` implementation:
`currency-lane-currency70-before-source-audit-20260906.json` and
`currency-lane-currency70-after-source-audit-20260906.json`.

| Metric | Before | After |
|---|---:|---:|
| Currency blockers | 51 | 33 |
| Quantified-evidence blockers | 449 | 449 |
| Semantic blockers | 181 | 181 |
| Coverage-summary blockers | 2 | 2 |
| Incomplete / missing issuer coverage | 0 / 0 | 0 / 0 |
| Guidance rows | 86,520 | 86,520 |
| Raw source tickers | 533 | 533 |
| Expected issuer reviews | 536 | 536 |
| Usable events | 16,108 | 16,126 |
| Research events | 70,412 | 70,394 |
| Independently validated typed currency contracts | 52 | 70 |

Both full-source audits correctly return `blocked` and exit 2. These are source
diagnostics, not a final two-run full-universe model-release certificate. Many
Disney quotes concern component changes or timing shifts, not whole-company
guidance; those semantic/economic concerns were neither removed nor approved.

## Tests and freeze

25 targeted Python and 21 Node tests pass. Tests include all nine real original
statement proofs, existing evidence variants, wrong CIK/currency/year, future
filings, old/new issuer boundary crossings, missing or duplicate facts, fake
namespaces, segment/scenario substitutions and rehashed semantic mutations.
`git diff --check` passes. No commit or deployment was performed.

```sh
python3 -m unittest scripts/test_validate_legacy_parent_statement_currency.py scripts/test_validate_gev_nwsa_currency_primary.py scripts/test_apply_event_guidance_currency_evidence.py scripts/test_validate_bg_maa_currency_primary.py scripts/test_rebind_bg_maa_currency_ledger_v32.py
node --test server/eventGuidanceCurrencyEvidenceAudit.test.js
```

The scoped applier, independent currency validators and currency registry are now
frozen for the main process's full recalculation. No additional issuer batch is
included.

## Remaining gaps: new Cigna 3 and early AbbVie 4

**New Cigna:** the three 2019-02-01 guidance events below belong to the merged
group, CIK 1739940. The old group's annual filing does not independently establish
the new group's presentation currency. A suitable pre-event merged-group or
pro-forma statement and dated continuity proof have not yet been completed.

- `1b5b9afdfe3ce2243104b464` — consolidated adjusted income from operations.
- `4ae06654b96244e45aae3a8f` — consolidated adjusted income from operations.
- `ef1180ddb222de81eb041a2a` — consolidated revenue.

**AbbVie:** three 2013-01-30 EPS guidance events require pre-event evidence for the
new standalone group, CIK 1551152. The retained
[2012-11-30 information statement](https://www.sec.gov/Archives/edgar/data/1551152/000104746912010903/a2209760zex-99_1.htm)
has combined standalone financials but no original XBRL instance in its filing
directory. The inspected statement did not yield an unequivocal global USD
presentation declaration. A derivative table referring to USD receipts is not
sufficient. A later March annual filing cannot be backfilled into January.

- `023427655f7ffcdbefd889fa` — 2013-01-30 quarterly EPS.
- `8bbde103778ac1907b06ee13` — 2013-01-30 annual EPS.
- `b6d3ad1a2f9f89efd4823cb4` — 2013-01-30 annual EPS.

The remaining 2013-04-26 EPS event, `09d7e89471d35a5530129417`, has a potentially
supporting combined-group accounting inference in the
[2013-03-15 annual filing](https://www.sec.gov/Archives/edgar/data/1551152/000104746913002827/a2213529z10-k.htm):
its combined presentation basis and currency-translation policy need to be
reviewed together. That would be a separately reviewed inference contract, not
this batch's original-XBRL contract, and was **not applied** before scope freeze.
This is incomplete review, not a claim that no possible evidence exists.

The complete remaining 33 currency blockers are ABBV 4, APA 1, ARM 2, AVAV 2,
CI 3, CSGP 3, FERG 3, ICE 2, LIN 1, PSKY 2, Q 1, TSLA 1 and XYZ 8. They remain
visible and blocking; no weak revenue-currency or foreign-subsidiary inference
was used to clear them.
