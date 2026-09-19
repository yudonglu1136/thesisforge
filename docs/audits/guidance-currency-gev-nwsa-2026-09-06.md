# GEV / NWSA dated reporting-currency repair

QA status: **currency evidence passes; full release remains blocked**.

This two-event batch follows the filing/QoE review and model-audit workflows:
company/group ownership, original filing availability and units are independently
checked; currency approval does not approve forecast amounts or target years.
No production database, financial source row, Guru holding or model was edited.

## Primary evidence and bounded scope

| Issuer | Guidance event | Prior official evidence | Treatment |
|---|---|---|---|
| GEV | 2024-04-25, `99db92ac9e105e032d544068` | [2024-03-05 Form 10-12B/A exhibit](https://www.sec.gov/Archives/edgar/data/1996810/000119312524059354/d542465dex991.htm) explicitly defines the GE Vernova carve-out group and declares USD reporting currency | USD currency only; not the GE Aerospace parent, and not a revenue-currency inference |
| NWSA | 2013-11-11, `b16468d693c7d2867723e024` | [2013-09-20 Form 10-K](https://www.sec.gov/Archives/edgar/data/1564708/000119312513373501/d581644d10k.htm) explicitly states USD company reporting currency for consolidation | USD currency only; not subsidiary functional currency |

Both full original HTML files, filing-header/index files, exact company/group
definitions and declarations are hash-bound. The independent JavaScript auditor
also parses the original filed date, CIK, accession and form from the retained
header text. Modified dates/headers and foreign-subsidiary or revenue-only
substitutions fail. Access is limited to these exact two event IDs and dates.

GEV's already-filed March 5 document was marked Subject to Completion; that
limitation remains attached. No forecast numbers are sourced from that document.

NWSA still has a separate semantic concern: `guidance_target_year=2012` refers to
the historical CapEx comparison, not the future target year. Its original amount
375m and target year were not changed or approved by this currency batch. The
separate guidance lane has been notified.

## Before / after, using the same current source checker

| Metric | Before | After |
|---|---:|---:|
| Currency blockers | 53 | 51 |
| Quantified-evidence blockers | 438 | 438 |
| Semantic blockers | 167 | 167 |
| Coverage-summary blockers | 2 | 2 |
| Incomplete / missing issuer coverage | 0 / 0 | 0 / 0 |
| Guidance rows | 86,520 | 86,520 |
| Usable events | 15,933 | 15,935 |
| Independent typed currency contracts | 50 | 52 |

All 52 contracts independently pass on the actual output DB. All prior 50
registry entries, financial rows and unrelated source rows are identical.
The only updated fields are SQL currency, payload currency, payload currency
resolution and typed official-currency evidence. Both target rows were first
compared in full, including raw payload bytes, with their reviewed v32 source;
they were exact before applying evidence.

## Artifacts

Paths are relative to `output/guru-valuation-expansion-2026-09-05/`:

- Input: `additive-full-rebuild-v30-four-20260906/source-v32-currency50-crdo-replayed.sqlite`,
  SHA `6b26c48b32a69a5fd6a9208cc2c5f727ee609042b2189db0154754d39c607f5d`.
- Candidate: `currency-lane-source-v32-currency52-20260906.sqlite`,
  SHA `ed5ebfc85b48dcc0bac11c2842da8e9e9062f4f1000513037b1b9242235f1f62`.
- Registry: `currency-lane-currency52-registry-20260906.json`,
  SHA `03a2b7f90240728d6f33893972cb46e9dce2fdadac8c7663b723b05d9792d8f0`.
- Ledger: `currency-lane-gev-nwsa-direct-ledger-20260906.json`.
- Exact preservation report: `currency-lane-currency52-apply-20260906.json`.
- Full source audits: `currency-lane-currency52-before-source-audit-20260906.json`
  and `currency-lane-currency52-after-source-audit-20260906.json`.

## Verification

20 targeted Python tests and 17 Node tests pass, including all prior 50 actual
currency fixtures, both new original-header fixtures, wrong issuer, future filing,
altered original document, changed group definition, missing headers, and changed
header semantics even when test hashes are recomputed. The actual original-file
applier verified both frozen HTML sources and both original filing headers.
Both complete source audits correctly return `blocked`; this is not a final
two-run model-release certificate. No commit or deployment was performed.
