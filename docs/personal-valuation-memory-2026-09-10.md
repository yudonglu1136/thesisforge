# Prefilled, private valuation worksheets — 2026-09-10

Mechanics QA: pass; economic starting assumptions require user review.
Local preview only. Supersedes the blank-template policy in
`personal-valuation-independent-2026-09-10.md`. No published valuation, financial
source rows, broker positions or decisions changed.

## Default inputs

Existing supported FCFE templates retain their exact cash-flow reconciliation.
Eligible operating-company/growth routes with exactly zero published DCF weight
and no DCF component receive `personal-starting-hypothesis-v1`:

- Stored, dated normalized growth, bounded to −50%–50%, fades linearly to
  2.5% in Year 5. Missing growth uses an explicitly illustrative 5%.
- Cash conversion: positive stored cycle CFO-minus-capex margin (at least four
  samples), otherwise positive TTM margin, otherwise explicitly illustrative 3%.
  Starting margin is bounded to 0.1%–60%. Seed provenance records raw anchors,
  sources, bounds, sample count and assumed recovery from nonpositive cash flow.
- Ke 10%, g 2.5% are editable illustrative assumptions, not market rates or
  management guidance. Historical CFO-minus-capex is not verified parent FCFE.
  Formal scenarios still require tax, interest, reinvestment and ownership review.
- Banks, customer-cash, ownership-specific routes and mixed currencies remain
  excluded. No missing actual is changed into a number.

Read-only AMZN example at 2026-08-28: growth 13.365668%, 10.649251%, 7.932834%,
5.216417%, 2.5%; margin 2.426471% each (eight-sample stored cycle anchor).
Revenue base USD 775680m, shares 10786.313572m, reported TTM FCF **−7604m**,
unchanged. This hypothetical positive-cash-conversion path produces
**$30.283022/share**, not the unchanged published **$230.925070** earnings model.
The gap between methods is not evidence that the stock is mispriced.

## Account memory

`POST /api/investment/valuation-drafts` uses authenticated server-side identity.
Hashed `valuation_draft` revisions are append-only in the existing private
investment SQLite DB, separate from licensed financial sources. Records contain
ticker, cutoff, snapshot/base, name, hypothesis, growth/margins, Ke/g, provenance,
parent version and server-derived calculation/validation error.

- 650ms edit debounce; calculation remains independently debounced at 400ms.
- Requests serialize. Timeout retries reuse the exact operation ID and payload
  before sending newer edits. A transactional expected-head check returns 409
  to stale tabs instead of overwriting their newer counterpart.
- Restore the latest owner/ticker draft or scenario whose cutoff is no later
  than the selected date. New data changes results, not saved assumptions; the
  UI explicitly discloses recalculation. Future assumptions cannot leak backward.
- Explicitly named legacy `LOCAL QA —/–/- ...` scenarios remain in history but
  do not become automatic defaults. No records are deleted or modified.
- Invalid/partial inputs can be remembered, but produce no valid DCF. A draft
  cannot authorize a decision, create a position or confirm FCFE ownership.
- In-app navigation flushes pending edits; save failures show retry and leave
  warnings. Closing the browser before acknowledgement can lose in-flight
  input: wait for the saved indicator.
- Opening a page is read-only. Existing user assumptions take priority over seeds.

## Verification

Backend tests cover default arithmetic/bounds, account/ticker isolation, DB
reopen, historical cutoff/new base, immutable versions, idempotency/conflicts,
invalid inputs, authenticated no-store HTTP and legacy QA exclusion.
Widget tests cover populated inputs, refresh restoration, hypothesis/name,
rapid edits, retry, partial inputs, changed data and navigation flush.
Browser acceptance uses real AMZN data read-only; save tests use isolated
synthetic fixture databases, not the user's actual portfolio.
Analyzer, bilingual audit and release web build also run locally.

Final results: **437 full Flutter tests passed**, **131 investment backend tests
passed**, analyzer has no issues, bilingual audit and release build pass.
AMZN was visually checked at 1600×1050 EN and 390×844 ZH; all five input years,
derived cash flows, terminal value and save-state copy render. Browser error
logs contained no error-level entries. The existing local QA scenario is still
in history, but the first-open sheet uses the new disclosed seed. No test edits
were written to the owner's account during browser checks.

Changed files: investmentMath/Source/Drafts/Service/Routes server modules;
workflow/valuation/valuation-memory/workspace-pages/graphite Flutter parts and
main part registration; related backend/widget tests and documentation.
Unrelated worktree changes preserved. No GitHub/AWS/production deployment.
