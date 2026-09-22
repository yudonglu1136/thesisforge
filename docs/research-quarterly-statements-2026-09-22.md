# Research quarterly statements and growth tooltips

## Scope

Research overview's shared income statement, balance sheet and cash-flow chart
now has Annual / Quarterly · Q controls. Quarterly mode displays the eight
quarterly observations already supplied by the PIT-selected Fact OS endpoint.
Switching frequency or statement reuses the loaded facts without another API
request. It does not change the research cutoff or published valuation model.

Hover on desktop, or tap on mobile, to inspect each selected line item's full
amount, YoY, QoQ, report-period end and disclosure date. Up to three selected
rows continue to drive the chart. The frequency is retained across statement
switches. New labels, missing states and explanations are bilingual.

## Calculation contract

- Growth = current / comparable base − 1. YoY matches the same fiscal quarter
  one year earlier; QoQ matches exactly the prior fiscal quarter, not the next
  available row. Non-calendar fiscal periods use their fiscal labels.
- Missing or ambiguous comparison periods stay unavailable. A zero or negative
  base is explicitly not meaningful, not an infinite or misleading percentage.
  Positive-to-negative changes remain valid. Known different currencies do not
  produce a growth percentage. QoQ is not seasonally adjusted.
- Annual/TTM points do not claim quarterly growth. Latest balance-sheet points
  may compare to the preceding quarterly balance. TTM requires four consecutive
  quarters with complete values and no conflicting known currencies.
- Quarterly dividends per share sum for TTM. Weighted-average shares are not
  synthesized without the required period-day weights.
- Existing endpoint coverage remains eight quarters. The oldest displayed
  quarters can therefore lack a prior-year comparison; the tooltip says so.
  No extra historical data, currency conversion or inferred periods were added.

## Verification

- Focused tests: 25 passed (`research_financial_growth_test.dart` and
  `investment_research_test.dart`). Covers EN/ZH, desktop/390px, frequency and
  statement switches, hover/tap values, no refetch, missing/duplicate quarters,
  non-calendar fiscal periods, zero/negative bases, currency mismatch and TTM.
- `flutter analyze`: no issues. `npm run audit:i18n`: passed.
- `npm run build`: passed. `git diff --check`: passed.
- Full Flutter suite: 559 passed, 32 failed. All 32 failures were reproduced on
  the clean pre-change commit `f338dc9dece114735d2566be82b650dc9a9c13d7`;
  failing test names match exactly, with no new failures. Existing failures are
  in Discover lenses (27), growth quality (2), valuation memory (1), portfolio
  Gurus (1), and opportunities (1). No assertions were removed or weakened.
- Live local AMZN at cutoff 2026-09-21: Q2 2026 revenue tooltip reports
  YoY +19.6% and QoQ +10.5%, with period end 2026-06-30 and disclosure
  2026-07-31. EN/ZH desktop and 390 × 844 layouts and touch tooltip verified.

## Release boundaries

Frontend-only; no API, database, credentials, scheduling or historical model
writes. Unrelated dirty workspace files are excluded from the commit.
Production authentication remains enabled. Rollback is to the prior Vercel
deployment `dpl_GGVZ3WB9vPfXTde3B9CaF3EpJZzc`, assigning both public aliases
together. Authenticated production interaction requires a signed-in session;
local browser checks do not stand in for that verification.
