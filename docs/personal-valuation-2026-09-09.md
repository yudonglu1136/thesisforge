# Personal valuation worksheet — 2026-09-09

## Terminal-edit repair (same-day follow-up)

Model QA: **pass for calculation and input handling; economic assumptions remain
user scenarios**. This does not revise the published NVDA valuation or source data.

| Finding | Cause | Repair |
| --- | --- | --- |
| Entering g = 8% left the worksheet as dashes | Both frontend and server reject g outside 0%–5%; the error appeared in a global banner above the scrolled viewport | Show the range and validation message beside Ke/g, highlight invalid rates, and resume automatically on valid input |
| First edit could drop keyboard focus | Conditionally inserting the unsaved-draft label changed sibling positions in the scenario editor | Stable draft-message slot and keyed rate controls; test focus retention in both languages |
| A pending/failed calculation looked like a frozen worksheet | No local request state or bounded timeout | Local live-region status, 12-second client timeout and calculation-only retry; never reload or discard the draft |
| Terminal value amount was hard to find | Diagnostics exposed only terminal PV and share | Always-visible terminal summary: year-5 TV, its PV, explicit-period PV, terminal share, units and formula |

The 5% maximum is an existing model policy, not the mathematical convergence
condition for all DCFs. The current guard also requires Ke − g ≥ 1.5 percentage
points; neither guard was relaxed. No silent clamping occurs. Invalid inputs
remain editable; they cannot be saved as a calculated scenario. Prior results
are not passed off as values for the new assumptions. Annual inputs and hypothesis
text stay intact through errors and retries. Late responses cannot overwrite a
newer or invalid draft.

Read-only local NVDA API checks, same 2026-08-28 source snapshot and Base forecast:

| g | HTTP | DCF/share | Year-5 terminal value ($m) | Terminal PV ($m) | Terminal share |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 3.35% | 200 | 135.51336169 | 4,023,210.230635 | 2,334,524.252764 | 71.4824% |
| 4.00% | 200 | 144.57064238 | 4,399,384.604401 | 2,552,804.717487 | 73.2690% |
| 8.00% | 422 | — | — | — | `invalid_terminal_spread` |

Explicit PV stays $931,347.763951m in the two valid rows; only g changes.
Terminal PV + explicit PV reconciles to equity value within $0.001m.
These are stored-model checks, not fresh investment recommendations.

Verification: 275 full Flutter tests (including 21 personal-worksheet tests),
53 investment/workflow/opportunity backend tests (41 core workflow tests).
Six added widget cases cover bilingual invalid
inputs, focus, recovery, visible terminal values, timeout/retry, failure/draft
preservation and stale-response rejection; one added server test checks exact
TV/PV reconciliation and accepted/rejected terminal boundaries. Flutter analysis,
i18n audit and the local release build passed. Real-browser checks at 1720×1120
and 390×844 verified inline 8% rejection, retained active input, successful 4%
recovery, terminal amounts, save gating, and both languages. No browser errors.
Screenshots are under `output/personal-valuation-20260909/terminal-*.jpg`.
No production deployment, Git push, source refresh or user-record write is part
of this repair. Browser checks use a separate preview tab and do not reload the
user's original unsaved worksheet.

## Delivered scope

The existing Research → Valuation screen is now an editable five-year worksheet,
not a read-only financial comparison. It uses the selected Graphite visual system,
existing company logos and native Flutter controls. The old terminal, research
history charts, management evidence, ownership evidence and decision workflow remain.

- Years are columns; revenue, growth, parent-common FCFE margin, resulting FCFE
  and discounted value are rows. Historical TTM figures are locked and separately
  identified. Left-hand row names remain visible during horizontal scrolling.
- Revenue and growth are two input controls for **one** growth path. Editing a
  revenue amount derives that year's growth from the exact preceding revenue;
  later years retain their existing growth rates. The server computes and saves
  all resulting annual revenue/FCFE amounts. Untouched inputs preserve full
  precision instead of saving their rounded display strings.
- Personal value, dated market price, value/price gap and the platform's separate
  published value are visible together. Bear/Base/Bull, Ke/g sensitivity,
  reverse valuation and the cash-flow audit remain available.
- The user's hypothesis text, scenario name, inputs, result, source snapshot,
  calculation version, timestamp and parent version are stored in the backend.
  Saving is explicit; it is not autosave. A failed save retains the draft.
- Reload selects the most recent saved version matching the current snapshot.
  Earlier versions are selectable. Editing a version creates a draft; saving
  appends a version and preserves the original. Applying older assumptions to a
  new snapshot is explicitly marked as a new, unsaved calculation.
- The Financials & sources comparison is now full-width, with separate actual,
  prior, percentage-point change and observed percentile columns; it links back
  to the hypothesis editor. This table remains read-only.

## Backend and privacy

`registerInvestmentRoutes` derives ownership exclusively from authenticated
`req.user.id`, never a body/query owner. Source company data is shared read-only;
scenario records are queried by owner. Responses are `private, no-store`.

The existing append-only SQLite event store records each scenario separately.
UPDATE and DELETE triggers prohibit overwriting saved versions. Cross-owner
parent versions and decision links are rejected. Results are recomputed by the
server; caller-supplied fair values are ignored. Idempotent retries preserve the
same record. Hypothesis text is limited to 4,000 characters; names to 80.

These are account-level application authorization controls, not an assertion of
end-to-end encryption. No production authentication behavior was changed.

## Financial model QA

**Status: pass for calculation/adapter mechanics; caution on economic assumptions.**
This is not a fresh underwriting of NVDA or a verification of every stored source
excerpt. The user's inputs remain hypotheses, not issuer guidance.

The NVDA read-only bug came from the adapter allowing only `operating_company`.
Its released route is `multi_method_growth`, with an explicit 32% FCFE DCF
component. The allowlist now admits these two routes only when a valid FCFE
component, current share count and comparable model/quote currency exist.
Banks, insurance, customer-cash, unknown and ownership-specific routes remain
excluded rather than being forced into a generic FCFE worksheet.

Base uses the stored model-forward revenue for year one when supplied, then the
released cash-flow growth path for later revenue. Each year's FCFE margin is
derived to reproduce that year's released cash flow. This is an explicit
mechanical starting hypothesis, not management's five-year revenue forecast.
Unscoped or quarterly management excerpts are not silently copied as annual inputs.

Calculation remains `investment-fcfe-v1`:

```
Revenue[t] = Revenue[t−1] × (1 + growth[t])
Parent FCFE[t] = Revenue[t] × parent FCFE margin[t]
Equity PV = Σ(FCFE[t]/(1+Ke)^t) + FCFE[5](1+g)/(Ke−g)/(1+Ke)^5
Per-share value = Equity PV / current PIT ordinary shares
```

Five annual periods run from the selected cutoff; displayed annual endpoints are
not claims about the company's reported fiscal year. Taxes, interest, capex,
working capital and parent attribution are included in the user's FCFE margin.
No second net-debt/NCI deduction or separate dividend/buyback addition occurs.
Actual CFO−capex is not mislabeled as audited parent FCFE; the historical FCFE
margin cell remains unavailable. Saving requires explicit ownership confirmation.
Negative-FCFE turnaround cases are outside this model's supported bounds and
receive an actionable error, not a fabricated valuation.

### NVDA reconciliation (local stored snapshot, cutoff 2026-08-28)

| Item | Amount |
| --- | ---: |
| Reported TTM revenue | $302,969m |
| Model-forward first-year revenue | $434,556.7675m |
| First-year implied revenue growth | 43.43274972% |
| First-year FCFE margin | 41.92046051% |
| First-year FCFE | $182,168.1981097241m |
| Shares held fixed | 24,100m |
| Ke / terminal growth | 11.5% / 3.35% |
| Worksheet Base DCF before post-DCF adjustment | $135.5133616893938/share |
| Published DCF component | $130.09282722181806/share |
| Difference | $5.420534467575749/share |
| Stored cycle multiplier | 0.96 |
| Published blended fair value (unchanged) | $274.8572171026456/share |

The four-percent cycle haircut reconciles the two DCF figures exactly. It is not
silently applied to the personal scenario. The platform's 36% EV/sales + 32%
normalized earnings + 32% FCFE result is not compared as if it were standalone
DCF. GOOGL's Base DCF remains $174.1081593417662/share, matching its published
standalone component within floating-point precision. No published valuation
database rows were edited.

## Verification

- 269 full Flutter tests passed: 254 prior plus 15 personal worksheet tests.
  Covers EN/ZH desktop/tablet/phone, large text, all five columns, linked revenue
  and growth, precise untouched ratios, blank/invalid inputs, save failure,
  reload restoration, parent versions, late response rejection and unsaved notes.
- 52 workflow/backend tests passed, including independent hand calculations,
  cash-flow preservation, post-DCF reconciliation, bounded stress templates,
  forbidden routes/currencies, cross-owner reads/writes, HTTP ownership spoofing,
  immutability, reopen persistence and untrusted client-result rejection.
- 41 performance regression tests passed. Static analysis, bilingual audit and
  release web build passed. No performance improvement claim is made.
- Real browser save test used a separate `browser-qa.sqlite`, never the user's
  research event store. Changing NVDA year-two revenue to $600,000m produced
  $146.6398995360847/share and persisted as v1. Reload restored the inputs and
  notes. Changing year-two FCFE margin to 38% produced $145.8548057199676/share
  as v2, linked to v1; both records and their original values survived.
  These values are **QA-only**, not investment assumptions or recommendations.

The normal local research database was restored after this browser test. The QA
database and screenshots remain under `output/personal-valuation-20260909/` for
inspection and are not included in a production deployment.

## Files changed for this request

- `lib/investment_valuation.dart`: worksheet, linked inputs, private notes,
  financial comparison, source reconciliation, diagnostics and responsive UI.
- `lib/investment_workflow.dart`: controller lifecycle, restoration, explicit
  private save payload and validation; `lib/investment_workspace_pages.dart`:
  new valuation layout routing; `lib/investment_graphite.dart`: named scenario
  panel, version selection and save confirmation; `lib/main.dart`: part binding.
- `server/investmentMath.js`: supported adapter package/forward revenue and
  bounded stress presets; `server/investmentSource.js`: route eligibility and
  reconciliation; `server/investmentService.js`: snapshot validation and notes.
- New personal UI tests and extended backend tests; updated existing workflow
  assertions and bilingual coverage ledger. Unrelated worktree edits preserved.

## Release boundary

Implemented and running **locally**, with real local backend persistence.
No GitHub push, AWS upload or production deployment was performed in this turn.
The workflow retains its existing preview-only production guard and the preview
build uses a development auth bypass. It must not be deployed as-is; production
activation requires the authenticated release configuration and persistence
migration review as a separately authorized release.
