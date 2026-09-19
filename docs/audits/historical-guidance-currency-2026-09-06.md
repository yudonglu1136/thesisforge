# Historical guidance currency repair — 2026-09-06

This is a source-only repair, **not a release authorization or model approval**.

## Integrated candidate

- Input: `output/guru-valuation-expansion-2026-09-05/full-reviewed-source-v30-official-dge-20260906.sqlite`
- Input SHA256: `325857ee1d65d6f12999a1debc18fc323adaf32257d8e56cef0af3ff2d4b58ab`
- Output: `output/guru-valuation-expansion-2026-09-05/full-reviewed-source-v30-official-dge-currency24-20260906.sqlite`
- Output SHA256: `0efb8a9f87c780ff21b736d703f59b6ee6dc75eb01b24723209bae90345a4414`
- Reproducible field-bounded report: `output/guru-valuation-expansion-2026-09-05/currency24-final-apply-20260906.json`

Exactly 24 guidance rows were enriched. Changes are limited to SQL `currency` and payload `currency`, `currency_resolution`, and `official_guidance_currency_evidence`. All financial rows, other guidance rows, issuer reviews, coverage, source ownership, quotations, amounts, units, growth, scope, and other source tables are unchanged. The original quoted currency remains explicitly null in the typed contract. No financial reporting-currency override is made.

## Evidence classes

| Issuer | Events | Evidence |
| --- | ---: | --- |
| TSM | 10 | Same-day SEC 6-K issuer releases explicitly quote US-dollar revenue ranges for the next quarter; exact range midpoints and quarters match the original calls. Native financial reporting remains TWD. |
| DDOG | 2 | Pre-event 2019-09-19 IPO prospectus directly declares company reporting currency to be USD. |
| GTLB | 1 | Pre-event 2021-10-14 IPO prospectus directly declares company reporting currency to be USD. |
| SHOP | 3 | Same-day 2015-07-30 and 2015-11-04 SEC releases state Shopify reports in USD. |
| CRWD | 2 | Analyst-reviewed inference: 2019-06-13 consolidated accounting policy translates subsidiary balance sheets into USD, income-statement items at period rates, and records adjustments in consolidated OCI. |
| PLTR | 3 | Analyst-reviewed inference: 2020-09-30 consolidated accounting policy translates non-USD subsidiaries into USD, with revenue/expenses and consolidated OCI treatment. |
| APP | 1 | Analyst-reviewed inference: 2021-04-15 consolidated policy translates whole non-USD subsidiary statements into USD, including assets, liabilities, revenue, costs and expenses. |
| ZS | 2 | Analyst-reviewed inference, lower evidence tier: complete 2018-03-16 Note 2 consolidation scope plus monetary/nonmonetary balance-sheet and revenue/expense USD remeasurement, with results recorded in parent consolidated operations. Not inferred from the subsidiary-functional-currency sentence alone. |

The 16 direct-primary cases and eight reviewed inferences are deliberately distinguished. The inferences are not described as literal reporting-currency declarations. Full original paragraphs, dates, CIK/accession identities, frozen document hashes, quote hashes and reasoning are preserved in each contract.

## TSM growth correction is separate from currency

The integrated v30 input already contains the original-quote growth-basis replay:

- 2024-01-18: sequential decline **−6.2%**, no stated YoY scalar in that quote.
- 2024-04-18: **6% QoQ**, **27.6% YoY**.
- 2025-10-16: sequential decrease **−1%**, **22% YoY**.

The currency applier does not overwrite these corrected growth fields. It does not annualize quarterly guidance or assert that quarterly outlook is a full-year forecast.

## Independent validation

`scripts/apply-event-guidance-currency-evidence.py` reads every frozen primary HTML document and verifies the whole document SHA256, exact normalized original paragraphs, issuer/CIK/accession, disclosure date, unchanged original event quote and source unit before creating a new copy. Duplicate events, existing output paths, conflicting/already-present currencies and future evidence fail closed.

`server/eventGuidanceCurrencyEvidenceAudit.js` independently reconstructs currency evidence meaning. A finite reviewed-document registry binds exact primary-document hashes, paragraph hashes, dates, issuers and event IDs; it cannot be widened by supplying another company's dollar paragraph. TSM additionally requires the same-day explicit USD revenue range, exact midpoint, original metric and next-quarter ownership. Inferences require full consolidation and translation/remeasurement context and remain labeled inferences.

The independent auditor requires actual SQL amount, unit, metric and fiscal period; null or missing source fields cannot borrow values from the contract. It does not rely on the producer's `currency=USD` alone. The validator deliberately has no dependency on private absolute cache paths; original whole-file verification is done by the source applier, while the release-side auditor uses the reviewed immutable hashes and independently parses the retained paragraphs.

Current lane regression: **92 Python tests + 8 Node tests passed**. These include the earlier additive assembly, official document fallback, DGE FX correction and BAE table-column repair tests; passing them does not replace the full 533+issuer source audit, model rebuild, independent two-run strict verification or release ledger.

## Integration boundary

The new candidate inherits the completed official-coverage/DGE branch and v30 original-source review chain. Integrate either this entire frozen source candidate as the new base, or precisely the 24 reported event IDs and four named currency fields into a byte-equivalent newer original-quote source. Never replace a newer transcript payload wholesale with an older evidence candidate. No deployment or commit was performed in this lane.

## Additive second batch: cumulative 34 events

The newer source is `output/guru-valuation-expansion-2026-09-05/full-reviewed-source-v30-official-dge-currency34-20260906.sqlite`, SHA256 `0e59d88ab3263e4a40bc6e9dd5162e039f37d9c9dc03b9387514ddba8b71b0e2`. It adds exactly ten events to the 24-event candidate; all earlier contracts and other source rows remain exact.

- ESTC: two early events use the 2018-10-05 IPO's explicit company reporting-currency USD declaration.
- GDDY: eight events use a clearly labeled presentation-currency inference from Desert Newco's complete parent-and-each-subsidiary USD policy, foreign-currency asset remeasurement, income/expense transaction treatment and consolidated operations. The IPO's GoDaddy/Desert Newco consolidation relationship (including NCI) is retained. A second, 2015-05-12 official SEC earnings release confirms that the IPO actually closed on April 7 and identifies the historical financial reporting predecessor. Both whole documents and exact paragraphs are hash-bound; conditional future consolidation is not assumed to have occurred without confirmation.
- XYZ: eight cases **remain blocked**. The original IPO's statement that most revenue is earned in USD and has little FX risk is not sufficient to determine consolidated presentation currency. Its first 10-K was filed on 2016-03-10 and must not be used to resolve the 2016-03-09 call retroactively. No USD classification was applied to XYZ.

The cumulative registry is `server/config/guidance-currency-reviewed-documents.json`, SHA256 `f051efcf9833fb4cfd76d2bc22ae745700d1f29a0061f59a4a85008c6591c5a0`. It retains the earlier registry entries exactly and adds two primary documents plus GoDaddy's secondary closing/predecessor confirmation.

Full integrated source-only audit: `output/guru-valuation-expansion-2026-09-05/currency34-full-source-audit-20260906.json`. All 34 target events have **zero source-audit failures**; currency blockers fell from **102 to 68**, exactly matching these repairs. Missing/incomplete guidance coverage is zero. Other current full-source findings are 389 quantified-evidence, 172 semantic and two aggregate-summary failures; therefore the source as a whole is still blocked and no model/release authorization follows. The non-currency improvement relative to an earlier source audit belongs to separate oracle work and is not attributed to these currency repairs.

### Reapply all 34 to a newer unchanged-quote base

Use `scripts/apply-event-guidance-currency-evidence.py` with a new source-output DB, new report and new registry path. Supply each of these five ledgers using a separate `--ledger` argument; all are under `output/guru-valuation-expansion-2026-09-05/`:

1. `tsm-event-currency-evidence-20260906.json` — 10 direct cases.
2. `ipo-reporting-currency-evidence-20260906.json` — six direct cases.
3. `ipo-reviewed-currency-inference-20260906.json` — eight initial reviewed inferences.
4. `ipo-next18-direct-currency-evidence-20260906.json` — two ESTC direct cases; its blocked entries are not applied.
5. `gddy-reviewed-currency-inference-v2-20260906.json` — eight GoDaddy inferences with already-published transaction confirmation.

If the newer source already includes the original 24 contracts, apply only the last two ledgers and pass `--existing-registry server/config/guidance-currency-reviewed-documents.json`. The applier refuses to overwrite an existing currency or strip inherited registered proof. All original quote hashes are rechecked; later parser improvements to growth/scope/ownership metadata are preserved rather than overwritten wholesale.
