# CRDO publication diagnosis and local repair — 2026-09-06

## Outcome

**Local CRDO model diagnostic: pass. Production publication: not completed.**

The published code release is `730dc21` / Elastic Beanstalk
`guru-admin-20260906-730dc21`. A read-only production check on 2026-09-06
at approximately 12:53 UTC still reports 533 valuation ticker snapshots, with
valuation generation `2026-08-30T10:30:00.000Z`. The preceding authenticated
Guru drawer check reports that no CRDO model has been published. Deploying the
typed missing-model message and Admin code did not publish CRDO financial data.

No production data mutation or additional code deployment was performed during
this repair. Neither a unit-test pass nor an isolated model pass establishes
production completeness.

## Source and model work completed

- Financial source lineage identifies Jansen Sharadar SF1 and the paid Sharadar
  fundamentals API. Historical selection uses earliest available `datekey` per
  fiscal period/dimension, with ARQ and separately identified ART inputs.
- Reviewed issuer evidence provides economic input corrections, including a
  sourced period-end share denominator. Original provider fields are retained;
  these corrections are not represented as unmodified paid-provider values.
- Two fresh independent CRDO imports used the same reviewed input manifest and
  fixed generation timestamp `2026-09-06T12:50:00.000Z`.
- Each contains 19 modeled historical periods and two explicitly unmodeled
  pre-IPO periods. Latest financial/model availability is 2026-09-02, for fiscal
  2027 Q1 (report period 2026-08-01).
- Each retains 170 guidance evidence events. The independent audit classifies
  84 as usable and 86 as research evidence; research evidence is not silently
  used as management forecast input.
- Q&A coverage is explicit for all 19 modeled periods: 18 have Q&A and one is
  `transcript_not_in_source`. All 108 Q&A pairs have English and Chinese fields.
  Exact-source translation bindings cover 216 unique fields; 209 use a passing
  generation audit and seven have explicit approval. This is not a claim that
  every translation received a new manual review.
- A material translation reversal was corrected: deferred Q2 IP revenue comes
  into Q3, rather than failing to enter Q3.

Both independent diagnostic reports have `failureCounts: {}` and status
`model_checks_pass_full_release_pending`:

| Signature | Both runs |
| --- | --- |
| Model | `54cf4d91edfe3856eb8da873f83b07e11a485ebaf031263b94b1f2d12ef0a60b` |
| Snapshot | `7355132eed5eb5ea5a6b5f2655d0a0c37a6b8b57fbb25b529ace0b83e4e1820c` |

## Independent guidance auditor repairs

Changed `server/guidanceCoverageReleaseAudit.js` and added
`server/guidanceCoverageReleaseAudit.scope.test.js`:

1. Preserve the fiscal-period qualifier when the same FCF amount repeats its
   metric name, e.g. an amount “of free cash flow in fiscal 2027”.
2. Bind per-share classification to the selected metric, preventing a later EPS
   clause from reclassifying an earlier operating-income dollar target.
3. Recognize a current forecast followed by commentary such as “as we had
   expected”; continue rejecting actuals and explicitly prior forecasts.
4. Retain forward context in a long main clause without allowing a historical
   metric to borrow an unrelated future expectation.

No release threshold or requirement flag was disabled. The producer and
independent auditor remain separate.

| Verification | Result |
| --- | --- |
| Focused guidance auditor tests | 211 passed, zero failed |
| `npm run test:server` | 1,042 passed, zero failed |
| Fresh CRDO import + Q&A enrichment + independent diagnostic, twice | Zero scoped findings; identical signatures |
| Full-universe diagnostic | Failed; not a release candidate |

On the same full-model candidate, `research_only_guidance_selected` findings
decreased from 904 to 557 after owner/context fixes. Remaining full-universe
findings include 38 incomplete currency reviews, 481 incomplete quantified
evidence reviews, 202 semantic classification conflicts, 216 silently ignored
usable-guidance findings, 244 research-exclusion mismatches, 218 scalar
contributor mismatches, 266 monetary contributor mismatches, and 108 incomplete
bilingual Q&A findings. These are findings, not distinct ticker counts, and
categories can overlap. Other coverage/translation-audit findings also remain.
Some newly recognized evidence exposes additional real source-review work;
the reduction in one category is not proof that all others are resolved.

## Publication blocker and required decision

`AGENTS.md` explicitly requires a complete additive-universe strict release
audit and disallows replacing that gate with two matching isolated diagnostics.
The existing `.platform/hooks/postdeploy/04-migrate-pit-valuations.sh` replaces
all seven valuation tables in one transaction. Feeding it a CRDO-only database
would remove other stocks; this was not attempted.

The user has been asked whether to authorize a new **CRDO-only additive release
path**, keeping all existing valuation rows, curves, user records and portfolios
unchanged. No approval was received at the time of this report. Until that
decision, the existing full-universe contract remains in force.

If authorized, an incremental path still needs implementation and tests for
exact scope, duplicate/conflict rejection, artifact hashes, two-run identity,
source and bilingual audits, transactional rollback, and semantic preservation
of all non-target rows. It also needs fresh production backups and actual
authenticated API/UI verification. It must not relabel the full universe as
passing or silently weaken the current full-release verifier.

## Other production finding

Elastic Beanstalk infrastructure is Ready/Green, but application health remains
failed because only 21 of 56 required Guru 5Y/10Y curves are current and
displayable. Database, Valuation, prices and delegated Ontology checks are
healthy. This pre-existing curve problem is separate from missing CRDO coverage;
an infrastructure-green deployment is not evidence that all product features
work.

## Private reproducibility material

Candidate databases, complete audit evidence and tests are stored locally under
`output/crdo-release-repair-20260906.QksCLJ/` (`run1`, `run2`,
`after-scope-audit.json`, and `server-tests.log`). Licensed financial rows, raw
transcripts, private manifests and these databases are not intended for the
public Git repository.
