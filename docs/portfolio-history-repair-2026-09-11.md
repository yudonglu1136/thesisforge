# Owner portfolio history and P&L repair

## Root cause and recovered evidence

Home had only the latest one-day broker report. The history loader was gated on
a separate History Query ID, although Flex v3 supports period overrides on the
existing Activity query. This supersedes the missing-history conclusion in
`personal-home-2026-09-10.md`; no separate History Query ID was needed here.

The owner-authorized AWS operator connection was used read-only, with credentials
held in process memory. Explicit `fd`/`td` requests returned broker error 1001 for
year, month and single-day probes. `p=30` and `p=365` succeeded. The API adapter
now validates both range forms; regular IBKR synchronization requests the last
365 days when no separate history query is configured. A failed history request
does not discard current holdings. No AWS settings, report configuration,
production database, connection credentials or trades were changed.

Recovered period: **2025-09-10 to 2026-09-09**, 261 distinct broker NAV dates and
837 distinct trade records. This is the returned broker coverage, not live data.
The report includes cash transactions, trade FIFO realized P&L and trade-date FX.
It does not include whole-position daily MTM, reconciled security transfers or
broker time-weighted returns. These omissions remain explicit.

Official protocol and field references:

- [IBKR Flex period/date overrides](https://www.ibkrguides.com/orgportal/performanceandstatements/flex3.htm)
- [IBKR SendRequest](https://www.interactivebrokers.com/docs/web-api/api-reference/send-request)
- [IBKR MTM statement-period scope](https://www.ibkrguides.com/reportingreference/reportguide/mark-to-market%20performance%20summary%20in%20base%20fq.htm)

## Product and metric contracts

The existing Flutter Home now has an inspectable chart with Account value,
Realized P&L and P&L estimate modes; 1M / 3M / 1Y / All; pointer/touch/date-slider
inspection; and selected-date amounts. P&L rebases to the selected date range.
The summary shows current NAV, latest period P&L estimate, full-report realized
P&L and position count. Cash/borrowing remains visible below the summary.
Winners & losers adds a separately labelled full-report realized ranking.
The chart range does not change that ranking: its own full-report dates remain
visible. Existing open-P&L and broker daily-MTM modes are retained.

| Measure | Computation and boundary |
| --- | --- |
| Account value | Actual broker `EquitySummaryByReportDateInBase.total`; exact common dates across accounts; includes borrowing, options and accruals. Not a return index. |
| Realized trading P&L | Sum of `fifoPnlRealized × fxRateToBase`, at trade date; distinct trade IDs; FIFO broker figures are not modified by subtracting commissions again. Excludes open P&L and account income/expenses. |
| Cash-adjusted P&L estimate | NAV change since the previous reported NAV minus reported cash deposits/withdrawals and internal cash transfers over the same interval. Dividends/interest/fees are not capital flows. |
| Estimate limitation | Security transfers and broker TWR are not reconciled. Never advertised as verified total P&L, actual return, Beta or Sharpe. A multi-day observation gap is an interval, not one day's performance. |
| Day winners / losers | Still requires single-day whole-position broker MTM. Trade-only `mtmPnl` does not represent all held instruments and is not substituted. |

Missing sections do not become zero. Explicit empty sections may establish zero
events. Unknown cash categories, bad dates, missing FX, duplicate trades and
missing P&L block the affected calculation. Different account identities or
base currencies cannot share history. Overlapping reports are never appended as
duplicate trades/cash flows; one complete matching report period is selected.

## Storage and privacy

Private immutable snapshot v3 adds structured `history_coverage`, `realized_pnl`
and `cash_flows` tables alongside `nav_observations`, positions and daily MTM.
Old v1/v2 snapshots remain readable and are preserved. Owner verification checks
all current/history account identities before import. The normalised copy omits
broker account numbers, contact details and credentials; source trade IDs become
one-way event keys. Raw files and SQLite are Git-ignored, mode 0600, in private
output directories. The loopback preview requires the matching owner hash and
development-only access guards. Nothing was uploaded or deployed.

Independent raw-report versus SQLite checks: 261/261 distinct NAV dates,
837/837 trades, cash-flow sum difference zero, realized-P&L sum difference below
0.000000001 (floating-point ordering only), exact latest position/NAV
reconciliation, and SQLite integrity `ok`. The Home API returns these records
after a backend restart, not an in-memory fabricated curve.

## Verification

- 67 focused backend tests passed: adapter requests, owner isolation, exact
  identity/currency joins, missing/empty sections, dates/FX, duplicates, P&L
  semantics, snapshots, risk and existing portfolio regressions.
- 11 Home widget tests passed, including new P&L mode/range rebasing and EN/ZH
  390px layouts at 120% text. Full Flutter suite: 462 passed.
- Flutter analyzer, bilingual audit, Ontology verification/tests, production
  build and development preview build passed.
- Browser acceptance uses the real owner data at 1440px and 390px, not test
  fixtures. Chart and realized ranking switches, range changes, reload and
  English/Chinese are checked. Private captures are under
  `output/portfolio-history-qa-20260911/`.

Local preview: `http://127.0.0.1:5186/?view=home&asOf=2026-09-10&lang=en`.
Do not deploy this dev-auth preview or private snapshot. Daily instrument MTM
and verified account TWR remain source-data requirements, not completed claims.
