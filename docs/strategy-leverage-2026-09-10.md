# Strategy leverage — local implementation, 2026-09-10

Requested replacement: fourth builder card after CTA is Leverage, with fixed
4% annual financing. The new builder sends no hedge payload and makes no
options-data request. Existing options data, standalone hedge code and legacy
saved rule records are retained. Opening a legacy hedge rule defaults leverage
to 1x and explains that a new version must be explicitly run/saved.

## Calculation contract

- Exposure multiple: 1.00–2.00, 0.05 increments; presets 1, 1.25, 1.5, 2.
- Scale the filtered stock and CTA weights, not a separate ETF leverage product.
  Cash from excluded/uncovered holdings offsets borrowing. If risky base weight
  is `w`, exposure is `L*w`; debt is `max(0,L*w-1)*postFeeNAV`.
- Reset only at existing disclosure rebalances. Between events the risky assets
  and equity drift. No daily constant-leverage or hindsight rebalancing.
- At each observed close: `interest = priorDebt * .04 * calendarDays / 365`.
  Capitalize that interest into debt; deduct it from equity. Weekends and
  holidays accrue. Cash earns zero. Corporate-action proceeds remain cash until
  the next disclosure rebalance, rather than silently changing financing rules.
- Reuse the existing audited unlevered gross curve and corporate-action marks.
  Between rebalances: `NAV = entryNAV*(1 + L*(gross/grossAtEntry-1)) - intervalInterest`.
- Actual post-fee trade sizes solve `postFeeNAV + k*sum(abs(newWeight*postFeeNAV-oldAssetValue)) = preFeeNAV`,
  with `k=costBps/10000`. Entry, purchases and sales are charged once. Cash
  settlements are not imaginary sales; stock conversions net successor claims.
- All existing 1x comparisons retain their prior cost convention and exact
  outputs. Leveraged results are additive, with their own curve, risk metrics,
  trade ledger and daily financing ledger. The UI discloses the small distinction
  between legacy proportional cost approximation and post-fee leveraged sizing.
- No margin calls, forced liquidation, variable funding rates or availability
  of broker lending are modeled. Nonpositive equity blocks the leveraged result;
  it is not floored at zero and not presented as limited loss. Independent
  unlevered curves remain visible. Sharpe retains explicitly labeled 0% Rf;
  borrowing cost is not silently reused as the risk-free rate.
- Owner-scoped, append-only saved rules include leverage and financing method;
  changing the leverage invalidates the prior run. Existing PIT, execution
  coverage and missing-data gates are unchanged.

## Verification

- 51 focused backend tests pass (strategy, financing, routes, legacy hedge).
- 400 full Flutter tests pass, including desktop and EN/ZH 390px at 150% text,
  run/save/restore, retained baseline, dirty state and ledger display.
- Flutter analyzer and bilingual audit pass; release web build succeeds.
- Real local DB/API smoke: Bill Ackman Top 5, premium cap30%, redistribute,
  KMLM30%, 10bps, L1.5, asOf2026-08-28, range2025-08-28–2026-07-31.
  232 daily rows and four rebalances. 1x net return -1.4781%, max drawdown
  -6.1244%; 1.5x net return -2.3983%, max drawdown -9.1885%.
  Cumulative financing0.06687 and transaction costs0.16005 per initial100.
  Minimum execution coverage100%; minimum valuation coverage20%, explicitly
  warned in the UI. Missing valuation slots remain cash, which offsets loans;
  these results do not certify complete historical valuation coverage.
  These are retrospective model outputs, not investment recommendations.
- Desktop browser acceptance: fourth card, selection, custom range, actual
  run, five comparison curves and financing summary reconcile to the API.
  No browser error/warning logs. No saved user scenario was created by QA.
- Known source limitation: Bill Ackman's 2026-08-17 execution fails existing
  `filing_classification_unverified`. Buffett/Smith have other unverified entry
  filings. Full windows crossing these records remain blocked; no data gate
  was weakened and no alternative data was silently inserted.

Local preview: frontend5186, backend8789. No AWS/GitHub deployment this turn.
