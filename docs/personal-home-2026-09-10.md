# Personal portfolio Home — local preview

Update 2026-09-11: the one-point-history blocker below is superseded by
`portfolio-history-repair-2026-09-11.md`. The same Activity Query with a 365-day
period override returned 261 real NAV observations and 837 trades. Home now
shows actual NAV, FIFO realized P&L and explicitly qualified cash-adjusted P&L
estimates. Broker instrument MTM / verified TWR are still not in this report.

## Product change

Home now opens the authenticated owner's portfolio, not the Guru discovery list.
It answers: what is my account worth, what changed, what contributed, and what
should I research next? The existing research desk remains an explicit secondary
entry; Discover, Portfolio, quarterly Guru research and Strategies are preserved.

The native Flutter dashboard uses summary cards, an actual account-value history
chart (1M / 3M / 1Y / All and date inspection), signed Winners / Losers, stock logos
and holding-to-research links. Portfolio retains full valuation, risk and Guru
comparison. Empty accounts reuse the masked IBKR connection form.

## Metric contracts

| Item | Source / calculation | Guard |
| --- | --- | --- |
| Account value | Broker-reported NAV, summed in the same base currency | Accounts must have the same report date; not a research-date reconstruction |
| NAV curve | Dated broker NAV observations; common dates across accounts | No forward fill, invented points or current-holdings simulation; deposits affect this curve |
| Day Winners / Losers | IBKR single-day MTM instrument totals in base currency, signed amount | Monthly/undated statements, duplicate instruments, missing totals and mismatched account dates blocked |
| Session P&L | Sum of those reported instrument totals | Explicitly not whole-account return/P&L; financing, FX and account-level items may differ |
| Open P&L | (Reported position mark − reported costBasisMoney) × report FX | Equities only, units/FX reconciled; not daily performance; coverage shown |
| Model impact | Existing covered-equity model delta / net holding marks | Separate research cutoff; uncovered marks unchanged, not an expected return |

IBKR describes MTM as statement-period P&L. Only explicitly single-day statements
can enter the daily ranking. Reference:
[IBKR Flex MTM fields](https://www.ibkrguides.com/reportingreference/reportguide/mark-to-market%20performance%20summary%20in%20base%20fq.htm).

When daily MTM is absent but cost basis exists, the visible selection is **Open
P&L**, with both “not today's move” and a daily-data-unavailable notice. The Day
P&L control still explains the missing source. Missing does not become zero.

## Existing owner source / remaining data work

- Read-only owner-verified local IBKR snapshot dated **2026-09-09**.
- 1 account, 7 equities, 4 option positions, cash and accruals reconcile to NAV.
- Cost basis supports 7 / 7 equity open-P&L calculations.
- **Only one NAV observation and no instrument daily MTM section.** Actual
  historical curve and daily contribution figures therefore remain unavailable
  for this account. No hypothetical series is shown as actual performance.
- AWS operator connector has no history Query ID configured. User must enable a
  daily NAV history report and single-day instrument MTM report. Cash-flow-adjusted
  returns additionally need deposits/withdrawals or verified broker TWR.
- The raw history-query adapter now joins daily NAV by exact broker account ID
  and base currency. It never attaches another account's history by array order.

## Storage and API

- `GET /api/investment/portfolio-analysis?scope=home` uses the same authenticated
  owner and private/no-store response. It skips Guru books and retrospective risk
  simulations; full Portfolio still requests those on its own page.
- Normalized local snapshot v2 stores cost basis and daily instrument MTM in
  SQLite; v1 remains readable. The prior snapshot is preserved, not overwritten.
- Owner hash and original source SHA-256 were checked before rebuilding the
  private snapshot. Snapshot files remain Git-ignored and owner-readable only.
- Credentials, owner identity and account numbers are not returned in the Home
  response. No deployment, production write, trading action or automatic refresh
  job was introduced.

## Verification

- Full Flutter suite: **408 passed**. New Home suite: 8 tests, including EN/ZH
  narrow layouts, range/date controls, source errors, missing history, cumulative
  vs daily P&L, currency switching and exact holding navigation.
- Focused Node suites: **53 passed**, including owner isolation, NAV intersection,
  duplicate/conflicting dates, period MTM guards, cost basis/FX and private v2
  round-trip with v1 compatibility.
- Flutter analyzer, bilingual audit and release preview build passed.
- Browser acceptance uses the real owner snapshot, not the synthetic unit-test
  accounts. Data readiness gaps above are not marked complete by passing tests.

Preview: `http://127.0.0.1:5186/?view=home&asOf=2026-08-28&lang=en`.
This development build contains a local auth bypass and must not be deployed.
