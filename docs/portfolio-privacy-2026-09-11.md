# Portfolio privacy mode — 2026-09-11

## Scope

Home and the connected Portfolio analysis share a one-click **Hide amounts** /
**Privacy on · Show amounts** control (paired Chinese labels). The same-origin
browser remembers only the boolean preference under
`thesisforge.portfolio.privacy.v1`; no account data or credentials are persisted
by this feature. Read it synchronously before the first portfolio frame. A
storage read failure defaults to hidden; a write failure reports that the choice
only applies to the current visit.

This is screen privacy, not access control, encryption or removal of the
authorized API response from browser memory. Public company-research pages and
separate online/legacy account applications are outside this display control.
No broker, financial-source, price, valuation or historical database is changed.

## Display rules

| Surface | Privacy mode |
| --- | --- |
| Account overview | Historical NAV change versus first dated NAV; explicitly includes transfers, not investment return |
| Latest P&L | P&L / previous reported positive NAV; an estimate interval requires its exact reported previous date |
| Realized P&L | FIFO P&L / reported NAV at or before the period start; contribution, not trade ROI |
| Account-value curve | Selected-range NAV / first selected NAV − 1; axes and cursor use percentages |
| P&L curves | Rebased selected-period P&L / starting reported positive NAV; no normalization by P&L itself |
| Open-position ranking | Reconciled long-equity open P&L / cost basis, ranked by percentage |
| Daily / realized rankings | Instrument P&L / corresponding reported NAV, explicitly labelled account contribution |
| Portfolio details | Amounts, unit quantities, report/model prices and account labels masked; weights, risk metrics and valuation gaps retained |
| Research ledger | Collapsed and disabled while hidden because free-text notes may contain amounts |

Missing, nonpositive or nonfinite denominators remain unavailable, not 0%.
Conflicting duplicate NAV dates are excluded. No future NAV is used; base
currencies remain separate. Open P&L cost bases must reconcile to the displayed
instrument's reported P&L; missing/short/ambiguous cases show an unavailable
rate instead of an invented result. Monetary labels are replaced, not blurred
or merely made transparent. The amount-mode results and underlying data remain
unchanged. Switching modes does not send an API write or reload holdings.

## Automated verification

- 12 new privacy tests: positive-denominator guards, missing/negative/duplicate
  NAV, pure percentage chart data, reconciled cost bases, all chart modes,
  range rebasing, pointer inspection, normal-mode restoration, persistence on
  remount, Home/detail navigation, multiple currencies, units/account masking,
  keyboard activation, single-observation fallback, and 390px EN/ZH at 150% text.
- 37 focused portfolio tests pass; full Flutter suite: **491 passing**.
- `flutter analyze`, `npm run audit:i18n`, `npm run verify:ontology-module`,
  `npm run test:ontology`, `npm run build`, and built ontology verification pass.
- Also fixed a pre-existing slider semantics index overflow when switching
  between histories with different observation counts.

Release is local preview only, on port 5186 with the existing read-only
portfolio backend on 8789. Browser acceptance notes and privacy-only screenshots
are kept under `output/portfolio-privacy-20260911/`.

## Actual-browser acceptance

- Existing owner report loaded on the local Home page; one click replaced
  amounts with rates/masks. A fresh same-origin page retained the preference.
- Verified NAV range changes, clicked historical curve points, and exercised
  realized and estimated P&L with percentage cursor text and percentage axes.
- Navigated to `view=book` and the holdings tab: balances, account labels,
  prices and unit counts stayed masked; research notes stayed hidden.
- Inspected responsive 1280×720 desktop and 390×844 mobile layouts, English
  and Chinese labels, and the mobile percentage curve. No browser errors.
- Privacy-only screenshots: `home-en-desktop.png`, `home-en-mobile.png`,
  `home-zh-mobile.png`, `curve-zh-mobile.png` in the output directory above.
