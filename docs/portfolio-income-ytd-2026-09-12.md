# Portfolio YTD and income allocation — local preview

## User-facing behavior

- Home and Portfolio account-history controls include YTD alongside 1M, 3M,
  1Y and All. The year comes from the latest available observation, not the
  machine's current date. NAV keeps the actual last year-end observation as
  its opening baseline (within seven days before January 1). Missing year-end
  evidence is explicitly partial; no opening NAV is invented. Realized and
  cash-adjusted P&L continue to rebase separately for the selected period.
- Allocation has Position / Income modes. Position retains Holdings / Sectors.
  Income defaults to Income type (dividends, bond interest, cash interest and
  dividend substitutes); By source shows every contributing reported instrument,
  including former holdings. Its own report period is visible and is independent
  of the neighboring NAV chart's selected range.
- Hovering a donut segment or legend highlights both and updates the inline
  readout. Clicking pins a selection; exiting hover restores it. Legend tooltips
  carry the same data. Touch users select a slice/legend. Existing holding
  Research navigation is preserved.
- Privacy hides all monetary readouts and tooltip amounts; percentages remain.
  English and Chinese labels, missing/empty states and mobile layouts are covered.

## Income definition and source

Income means **positive reported cash income receipts**, before taxes, fees,
financing expense and negative income reversals. This is not net investment
income, yield, accrued income, an annual forecast or trading P&L. Negative
reversals are retained separately. Bond interest can include accrued interest
received in a trade; it is not all described as bond coupons.

The parser reads only detailed CashTransaction rows with exact broker income
categories. It preserves source currency/amount and transaction FX; no current
FX, position-market-value or future dividend-calendar estimate is substituted.
Missing sections, bad dates/FX/identity, unknown categories and duplicate event
identities prevent a claimed distribution. Explicit empty sections can establish
no recorded receipts. Account history intersects only compatible report periods;
the selected complete statement is never appended to overlapping statements.

The retained owner-authorized annual report covers 2025-09-10 through 2026-09-09.
All 30 relevant cash-income rows were restored into a new private immutable v4
SQLite snapshot, with 12 instrument/category sources. Raw-report and stored
counts and positive-receipt totals reconcile. The 261 NAV rows and all preexisting
position/P&L/history fields compare identically to the v3 snapshot. V3 is retained
for rollback. No account identifiers or credentials are added to normalized data.
V1–V3 remain readable with income explicitly unavailable. No production/AWS
database, broker configuration or trade was changed.

See the [IBKR Activity Flex reference](https://www.ibkrguides.com/reportingreference/reportguide/activity%20flex%20query%20reference.htm)
for the independently configurable statement sections. We use the original
retained cash report, not a dividend estimate service.

## Verification

- 526 Flutter tests pass, including eight new YTD/income/hover/privacy/mobile tests.
- 56 focused portfolio backend tests pass, including income classification,
  reported FX, invalid/duplicate/missing data, empty and negative-only reports,
  multi-account windows and v4/legacy snapshot persistence.
- Analyzer, i18n audit, Ontology verification, 3 Python + 22 Node Ontology tests,
  41 performance/transport regression tests, production build and local preview
  build pass. These checks are not a claim of measured performance improvement.
- Live local API returns income ready with 30 events and 261 NAV observations.
  Raw year-end NAV independently reconciles to the displayed YTD balance change.
  Balance changes include transfers and are not represented as TWR.
- Desktop and 390px browser checks use the actual owner snapshot with privacy
  enabled. Private QA images are kept under output/portfolio-income-qa-20260912/.

Local preview: http://127.0.0.1:5186/?view=book&asOf=2026-09-10&lang=en
