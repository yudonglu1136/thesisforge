# CRDO missing valuation — scoped repair, not a release

Status: **full additive private candidates generated; release audit blocked / not deployed**.
CRDO now has a reviewed, runnable 19-node model candidate. It has not been
committed to the production database or published, and this does not resolve
the full Guru coverage-expansion release blocker.

## Latest checkpoint — supersedes initial input-stage findings below

- CRDO is present in both complete V5 imports: 537 snapshots / 32,130 nodes,
  including 19 CRDO nodes. Their economic models and pre-enrichment snapshots
  are deterministic. Arithmetic, model/source dates, source lineage, temporal
  continuity and private-path checks pass; full guidance and Q&A release gates
  do not. This still does not make CRDO available through production APIs.
- Fresh normal English-Q&A enrichment on two separate V5 copies supplies all
  32,130 coverage statuses and 7,340 pairs. The new CRDO 108 pairs still need
  the final exact reviewed Chinese cache attachment; the full-platform cache
  remains incomplete. The earlier isolated Chinese cache below is not final:
  later review found a revenue-timing relation translated in reverse and other
  local expression issues. Numeric guards alone did not catch that semantic
  error. Source-bound corrected translations are retained in a separate
  reviewed package; no old aggregate approval is being reused.
- Latest full server suite: **1,031 pass**; Flutter **122 pass**;
  performance/transport **41 pass** (overlaps the server suite). Frontend build,
  analyzer, i18n and Ontology checks pass. No GitHub push, AWS migration or
  Vercel deployment has occurred. The following bullets retain the earlier
  isolated-model details and their dated audit identities.

- All 21 dated financial statement inputs have currency evidence; the two
  pre-IPO registration periods are explicitly non-modelable. Preserve them as
  source history, not invented pre-listing quoted valuations.
- All 19 listed-company periods reconcile reported cash flow, cash capex,
  technology-license financing payments, SBC, period-end common shares,
  warrants/options and other equity claims. Two absent ART financial sets were
  reconstructed from the exact then-available SEC statements. Original paid
  payloads and their hashes remain in lineage.
- Economic FCFE is distinct from reported CFO-minus-capex. Customer-warrant
  contra-revenue and cash/unrestricted investment versus funded-debt bridges
  are explicit analyst adjustments, not issuer-reported figures. Operating
  lease costs stay in CFO and are not charged again as funded debt.
- Historical 136% actual growth no longer contaminates the 97% forward guide.
  A separate early outlook retains its $45.5m quarterly revenue while splitting
  21% QoQ and 324% YoY instead of feeding sequential growth into a YoY input.
- Independently prepared fresh runs **3 and 4** each pass the isolated audit:
  **19 nodes, zero failures, 108 bilingual Q&A pairs, 19 coverage statuses**.
  One period explicitly has no transcript in the local source; no Q&A is made
  up for it. All transcript content is research-only, excluded from valuation.
- Local Qwen translation used a recorded semiconductor-domain context and
  numeric placeholders. Four exact source-bound editorial corrections retain
  prior translation hashes and reasons; 212 other fields pass the automated
  guards. This is not a claim that all translated text received human review.
- The two fresh runs have identical model signature
  `5a6cf81b84f3d5535e6a133c0074c01efdbbe449805f17eebd58cb6c30f6e857`
  and snapshot signature
  `3a35cc0364636aea62e31531ac988d9c8819583b128528c3de4dedfa0c9b5c07`.
  Reused run2 was not used to prove snapshot determinism: its JSON property
  order reflects earlier repeated imports, although its model signature and
  semantic values match. No verifier tolerance or canonicalization was changed
  to hide this difference.
- Flutter exposes economic/reported cash flow, SBC/license deductions, cash
  plus unrestricted investments, funded debt, operating leases and separate
  equity-claim adjustments. Four EN/ZH desktop/mobile presentation tests pass;
  analyzer and bilingual audit pass.
- The first full additive import now includes all 19 CRDO nodes alongside
  retained coverage: 537 snapshots / 32,130 total nodes. CRDO's original 18
  transcript files have also been replayed under v32 into a separate combined
  source. Full-platform guidance-consumption and bilingual-Q&A release blockers
  remain; isolated success is not a published CRDO API response.
- Latest whole-server checkpoint: **917 tests pass** (before subsequent lane
  additions). Latest whole-Flutter checkpoint: **122 pass**, including cash/lease
  and current-only EN/ZH desktop/mobile displays. Ontology tests and the
  built-module verifier pass. Final full-universe release and production UI
  verification remain outstanding.

Private reproducible candidates:
`output/guru-valuation-expansion-2026-09-05/crdo-model-run3-20260906/` and
`crdo-model-run4-20260906/`; each contains `model-audit-final.json`.
The trusted private source manifest is
`crdo-evidence-completion-20260906/crdo-reviewed-input-candidate-v4.json`.
Neither the private manifest nor passing isolated candidates activate CRDO in
the default production universe. No GitHub push, AWS or Vercel deployment has
occurred during this completion work.

The remaining sections preserve the initial diagnosis and earlier checkpoints;
their former source-gap counts are not the current model status.

## Diagnosis

- The user's September 6 screenshot shows CRDO missing in the Gavin Baker
  stock-research drawer. The September 5 production backup contains zero CRDO
  ticker snapshots, model runs and valuation financial inputs.
- The local input stage had 40 financial rows (20 ARQ + 20 ART), ending with
  FY2026 Q4, available June 15. The local licensed parquet was equally old.
- The existing paid API already supplies FY2027 Q1 ARQ/ART, available September
  2. This was a missed incremental ingestion, not absence of public financials.
- `loadValuationTicker` reads published snapshots; Retry never imports a model.
  Previously the HTTP route returned 404 for every exception and Flutter
  combined missing coverage with request failures.
- A fresh browser check reached the production login screen only. No newly
  authenticated production CRDO API/UI success is claimed.

## Changes made locally

1. Added copy-only, explicitly scoped paid financial refresh. It refuses to
   overwrite its input/output, rejects wrong securities, future/non-PIT rows
   and conflicting observations, preserves earliest retained history, and
   invalidates the updated issuer's review rather than approving a model.
   It never updates Guru prices or the runtime database.
2. Refreshed CRDO into a new private candidate: **40 → 42 financial rows**,
   latest availability **2026-06-15 → 2026-09-02**. Original files stay intact.
3. Repaired the official-guidance parser's fiscal-quarter heading omission.
   The September 1 outlook is now assigned to **2027-Q1**, retains **quarter**
   scope and resolves to USD through prior dated source evidence. The midpoint
   is $530m, not full-year guidance. Source:
   [Credo earnings release](https://investors.credosemi.com/news-events/news/news-details/2026/Credo-Technology-Group-Holding-Ltd-Reports-First-Quarter-of-Fiscal-Year-2027-Financial-Results/default.aspx).
4. Excluded compensation-plan revenue hurdles from operating-guidance
   candidates. The original SEC documents remain in the evidence cache.
   Paragraphs containing an explicit operating outlook remain reviewable.
5. Independently verified **19 of 21 dated currency targets**, enriching 38
   financial rows with evidence only. The January 3 and January 18, 2022
   targets remain unresolved; no currency or statement numbers were guessed.
6. Split the product states: typed `valuation_not_covered` returns 404/no-store;
   storage/parsing failures return sanitized 503/no-store; successful payloads
   preserve their existing cache and detail contracts. Missing publication no
   longer suggests Retry will generate coverage. Auth failures are separate.
7. Added CRDO as an **unreviewed queue entry**, not an active model. No generic
   semiconductor assumptions have been approved for historical publication.

## Initial model/source gaps (historical checkpoint)

- The scoped official review inspected five 2026 filings / ten documents with
  zero access errors. CRDO has 125 retained guidance occurrences, including
  nine usable official occurrences. **Five older quantified guidance events
  still lack resolved currency evidence**; coverage remains incomplete.
- Historical statement-currency gaps, guidance provenance, exact share-count
  dates, original fiscal-period alignment and Q&A must pass before publishing
  the historical curve.
- The [September 2 Form 10-Q](https://www.sec.gov/Archives/edgar/data/1807794/000162828026060111/crdo-20260801.htm)
  shows $90.231m CFO and $7.282m cash PPE purchases, but also $5.172m of technology
  license payments classified in financing and $87.979m SBC. CFO minus PPE is
  therefore not automatically parent-economic FCFE. Reconcile license costs,
  recurring SBC versus dilution, working capital, and acquisition cash/claims.
  Period-end shares are 187.768m at the filing's thousand-share precision;
  the staged 187.951918m count is the later cover-date observation, not the
  August 1 denominator. DustPhotonics contingent consideration also requires a
  consistent equity-claims treatment.
- After the scoped economic review, build two deterministic full additive
  candidates, preserve existing names/history, pass the strict verifier and
  all-ticker ledger, then use the normal backup/atomic migration/deployment
  process. No gate was weakened and no partial candidate was published.

## Preservation and verification

All six non-CRDO stage surfaces match the original exactly: financial rows,
raw financial review, guidance events, financial/guidance coverage and issuer
review. The comparison includes **34,249 non-CRDO financial rows** and **2,292
non-CRDO guidance events**. SQLite integrity is `ok`.

- Node server tests: **860 passed**.
- Flutter tests: **110 passed**; includes EN/ZH errors at 1280×720 and 390×844,
  retry recovery, wrong-ticker rejection and clearing values after auth loss.
- Python guidance suites: **159 passed** (including three new CRDO regressions).
- New candidate-financial refresh suite: **5 passed**.
- Performance contract tests: **40 passed**, overlapping the server suite.
- Ontology: **3 Python + 22 Node passed**; built module verifier passed.
- Flutter analyze: no issues. i18n, production web build and diff checks passed.
- Full model release verifier, production migration and authenticated browser
  end-to-end checks: **not passed/not performed for this repair**.

The model-audit workflow kept reported cash flow, management guidance and model
approval separate; fetching new inputs was not treated as a completed valuation.
Private inputs and currency ledgers are under
`output/guru-valuation-expansion-2026-09-05/crdo-repair-2026-09-06/` and must stay
out of Git. The initial local input candidate was `source-currency.sqlite`.

No GitHub push, AWS deployment or Vercel publication occurred in this repair.
