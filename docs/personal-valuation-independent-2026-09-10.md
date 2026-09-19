# Independent personal hypotheses — 2026-09-10

QA: **pass for mechanics and account isolation; caution for economic assumptions**.
Local implementation only. This does not publish a new AMZN valuation or change
the stored PIT financial/model rows. No investment recommendation is implied.

## Finding and implementation

AMZN's 2026-08-28 research snapshot has positive revenue and shares but negative
reported TTM CFO minus capex. Its published model assigns 100% to normalized
earnings and 0% to FCFE DCF. The adapter previously required a positive published
DCF weight to expose the personal worksheet, making it read-only.

The adapter now permits a **blank private worksheet** for explicitly
`operating_company` / `multi_method_growth` routes whose published DCF weight is
exactly zero and whose DCF component is absent. Positive finite revenue/shares
and comparable model/quote currencies remain necessary. Broken positive-weight
DCF records, unknown weights, financial/customer-cash/NCI-specific routes still
fail closed. Existing valid DCF templates are unchanged.

All five revenue-growth and FCFE-margin entries start null, not zero or invented
positive forecasts. Ke 10% and g 2.5% are labeled editable illustrative defaults,
not market-derived rates or management guidance. Blank templates have null
template results and cannot be calculated or saved until the user supplies valid
inputs. Historical negative cash flow remains negative and visible.

- Copy Year 1 to all years is an explicit action, after entering growth and margin.
- Revenue and growth remain two controls for the same forecast path.
- Automatic calculation is debounced; late/error/invalid results cannot replace
  current valid input state. No prior value is shown as the result of invalid inputs.
- The first successful calculation is held as the on-screen reference. Subsequent
  changes show per-share amount and percentage differences. The user can explicitly
  rebase the comparison. Company/date changes and saved-version restoration reset it.
- Sidebar shows the current DCF and reference while editing the table.
- Saving uses the existing authenticated-owner, append-only backend version store,
  with hypothesis, source snapshot, inputs, recalculated result and provenance.
  A local comparison reference is not a separate persisted valuation version.

## Model limits and reconciliation

This remains parent-common FCFE / Ke, five annual periods from the selected cutoff,
year-end discounting, fixed dated shares and Gordon terminal value. FCFE margin is
after tax, interest, capex, working capital and parent attribution, **not operating
margin**. There is no second debt/NCI deduction or dividend/buyback add-on.

The existing forecast bounds remain: every annual FCFE margin must be >0% and
<=90%; Ke 4%–30%; g 0%–5%; Ke minus g >=1.5pp. A negative historical observation
does not prove positive future cash generation. This feature does not yet value
a forecast containing loss years. Such inputs receive an explicit validation
message, not silently clamped values. No future fiscal guidance is inferred.

Independent arithmetic and actual local HTTP endpoint, AMZN at 2026-08-28:

| QA-only assumption change | Reference | Revised |
| --- | ---: | ---: |
| Revenue growth Y1–5 | 15%,15%,15%,15%,15% | 15%,20%,15%,15%,15% |
| FCFE margin Y1–5 | 8% each | unchanged |
| Ke / g | 10% / 2.5% | unchanged |
| Explicit cash-flow PV, USD m | 355235.068007 | 367859.416418 |
| Terminal PV, USD m | 1059158.507077 | 1105208.876950 |
| DCF / share | $131.12854226 | $136.56828012 |

Revenue base $775680m; shares 10786.313572m.
Independent calculation uses `R[t]=R[t-1]*(1+growth[t])`, `FCFE[t]=R[t]*.08`,
`PV=sum(FCFE[t]/1.1^t)+FCFE[5]*1.025/.075/1.1^5`, then divides by shares.
Change = **$5.43973786/share (+4.15%)**. Published $230.92506950 and absent
published DCF remain unchanged. These example assumptions were not saved to the
user's account.

## Verification

- 411 full Flutter tests passed, including 24 worksheet tests (3 new: bilingual
  blank-input/copy-year-one flows and fixed comparison/rebase/invalid-input flow).
- 111 investment backend tests passed, including 46 workflow tests (3 new:
  blank private adapter, excluded routes/bad data, calculation and private saving).
- Backend tests preserve immutable versions, cross-owner isolation, snapshot
  checks, recomputed server values and exact published-model separation.
- Analyzer, bilingual audit and release web build passed.
- Actual browser verified blank AMZN -> annual inputs -> copy -> $131.13 ->
  year-two edit -> $136.57 and +$5.44; EN/ZH at 390x844 and desktop; no console errors.
- Save/reopen persistence tested in isolated synthetic databases. Browser QA
  did not write new user records. No GitHub/AWS/production deployment.

Changed files: `server/investmentMath.js`, `investmentSource.js`,
`investmentService.js`, `investmentWorkflow.test.js`; `lib/investment_workflow.dart`,
`investment_valuation.dart`, `investment_graphite.dart`; worksheet tests and audit
documentation. All unrelated dirty-worktree edits retained.

Open underwriting questions belong to the user: five annual growth assumptions,
sustainable parent-common cash conversion, and appropriate Ke/g. The UI does not
answer those questions by selecting convenient positive estimates.
