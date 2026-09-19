# Real portfolio × Valuation × Guru × SPY

## Local delivery and source boundary

The owner's real IBKR report is now available in a private local SQLite snapshot.
It was retrieved read-only through the existing AWS Elastic Beanstalk operator
IBKR Flex connection, then checked against the expected owner before import.
This is **not a copy of the production per-user database**: direct server access
was unavailable. No AWS configuration, production portfolio, connection, trade,
valuation model or market-history table was changed. No deployment or Git push
was performed in this turn.

This supersedes the real-account-source blocker in the earlier
`portfolio-research-2026-09-09.md` delivery note, but does not certify actual
account return history or production acceptance of this preview.

## Data and security

- Private `output/owner-portfolio-20260910/portfolio.sqlite`: normalized `snapshot`,
  `accounts`, `positions`, and `nav_observations` tables. Source provenance,
  retrieval time and source SHA-256 are preserved. No credentials or contacts
  are stored in the normalized database.
- Original report and SQLite file are owner-readable/writable only (0600),
  inside a Git-ignored directory. The local server binds to loopback.
- Local snapshot access requires the explicit owner hash, snapshot path,
  workflow flag, development-auth flag, non-production environment and exact
  development identity. Other authenticated identities cannot select it.
- Normal users continue through the existing authenticated per-user broker
  loader. Analysis responses are `private, no-store`; browser owner IDs cannot
  select another portfolio. The public-input cache contains no account data.
- The imported report's account NAV reconciles exactly after retaining signed
  options, negative cash, dividend accruals and interest accruals. These rows
  must not be dropped or re-labelled as ordinary stocks.

## User workflow

`Portfolio → Overview / Holdings & value / Risk & SPY / Compare with Gurus`.

Overview displays reported NAV, marked exposure, borrowing, short-option count,
concentration, valuation coverage and marked stress scenarios. Holdings retain
company logos and Guru portraits, exact currencies, report/model dates and
per-holding contribution. The shared Alphabet economic model explicitly names
its GOOGL model source while retaining GOOG's own price; voting rights are not
valued separately. Unverified model currencies remain uncovered.

Risk & SPY offers an inspectable growth-of-100/drawdown chart, matched daily
return metrics, an adjustable risk-free assumption, covered/excluded holdings,
and a dated constituent-weighted valuation comparison. Negative model gaps use
the negative color in both comparison cards; relative cheapness is not confused
with an absolute discount to model value.

Users without a portfolio receive setup guidance and a masked Token + Query ID
form. The explicit Connect & sync action uses the existing encrypted, per-user
server connection endpoint. It does not ask for an IBKR trading password and
does not save credentials in browser storage. The local owner copy opens the
live authenticated account separately rather than falling into the legacy
development/sample account view.

IBKR documentation checked for this workflow:
[Flex Web Service configuration](https://www.interactivebrokers.com/docs/web-api/flex-web-service/client-portal-configuration)
and [token setup](https://www.interactivebrokers.com/docs/web-api/flex-web-service/client-portal-configuration/enable-and-create-access-token).

## Calculation contract

| Measure | Definition and limit |
|---|---|
| Per-position model value | Reported units × published per-share value × explicit report FX; ordinary long equity only, with units/currency checks. |
| Whole-book model impact | Sum of covered-position value changes / reconciled marked net holdings. Uncovered assets retain their report marks. Not a complete DCF of the account. |
| SPY relative valuation | `Σ[w × (FV / P − 1)] / Σ[covered w]`, with security-class SPY weights and exact same-date prices/model cutoff for both compared baskets. Not an average of dollar share values. |
| Coverage | Full eligible weight remains in the denominator; missing prices/models never become zero-value investments. Constituents unavailable at the cutoff are not backfilled. |
| Portfolio comparison weights | Latest broker report weights, explicitly dated separately from the price/model cutoff; not historical ownership. |
| Risk simulation | Current covered USD long-stock weights, daily rebalanced, using dividend-adjusted returns on SPY's exact common dates. A missing interior observation excludes the whole security; no daily reweighting around missing data. |
| Beta | Sample covariance with SPY / sample SPY variance, minimum 60 aligned daily returns. |
| Sharpe | `sqrt(252) × [mean(r) − ((1 + Rf)^(1/252) − 1)] / sample_sd(r)`. Rf is a visible assumption, not a fetched yield. |
| Volatility / drawdown | Sample daily SD × sqrt(252); drawdown from cumulative peak including initial capital. |
| Exclusions | Cash, financing, fees, taxes, options, shorts, foreign-currency returns and incomplete securities are outside the simulated return curve. Marked option value is not option risk capital. |

The current report contains only one NAV observation. Actual cash-flow-adjusted
daily account returns are therefore **not available**. Actual-account Beta and
Sharpe are withheld, not inferred from this point or replaced with simulated
metrics. Additional verified daily NAV and external cash-flow/TWR history is
needed for actual-account performance. LSEG's stored model lacks a verified
currency field; it remains visibly uncovered rather than guessed as USD/GBP.

## Verification

- 45 focused Node tests passed: source reconciliation, nulls, units/FX, dates,
  account isolation, encrypted connection recovery, weighted valuation,
  independent Beta/Sharpe math, missing-date exclusion and cache invalidation.
- 19 focused portfolio widget tests passed; full Flutter suite: **398 passed**.
  Includes both languages at 390px with 150% text, explicit connect submit,
  masked token, stock/Guru navigation and stale request protection.
- `flutter analyze --no-pub` and `npm run audit:i18n` passed; release preview built.
- Read-only real-data API acceptance: 200/ready, one owner account, exact NAV
  reconciliation, private/no-store response. Unauthenticated requests return 401.
- After restart, measured API times were 4,973ms cold, 149ms and 95ms warm.
  Public model/price caching improves repeat reads; these are local timings,
  not production latency guarantees.
- Browser checks exercise the real owner Overview, Risk & SPY, return/drawdown
  control and risk-free-rate re-computation, plus EN/ZH at 390×844 with no browser
  errors. No production credential submission
  was performed; connect writes are verified with an isolated test API.

## Preview

Frontend: `http://127.0.0.1:5186/?view=book&asOf=2026-08-28&lang=en`

Backend: `http://127.0.0.1:8789`, loopback development authentication.
Never publish the development-auth preview build or the private snapshot.
