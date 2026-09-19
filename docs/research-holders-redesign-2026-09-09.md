# Research holder workspace — 2026-09-09

## Outcome

Replaced the wide, portrait-free disclosure accordion with a searchable Guru
roster and a selected disclosure pane. Reused the project's Graphite design
system, original `GuruAvatar` assets and existing manager-history navigation.
This is a local UI change; no deployment, financial recalculation, user-data
migration or automatic decision save was performed.

## User journey

1. Research → Financials & sources → Who holds the selected company?
2. Compare reported shares and weight in each manager's disclosed long book.
3. Select a manager to inspect the exact share count, previous observation,
   raw difference and separate reporting/publication dates.
4. Open the SEC filing, explore that manager's history for the same ticker,
   or link the disclosure as a source when saving a personal decision.

Desktop uses a 60/40 split at at least 940px available content width. Phone
and larger text use an in-place disclosure expansion. Search does not silently
link a source; selecting another manager preserves explicitly checked sources.
Original entry attribution remains locked. Missing history is never zero and
unverified share differences are never labeled as confirmed buying/selling.

## Source fidelity

The existing local PIT research endpoint provides eight NVDA provenance rows
at 2026-08-28. All are retained. The default ordering is reported share count,
not a conviction or performance ranking. The displayed Baillie Gifford row
remains 41,888,806 shares, prior 40,748,665, raw change +1,140,141, reported
book weight 7.60%, position 2026-06-30 and public filing 2026-08-06.

All eight canonical avatar paths returned HTTP 200 and 144×144 PNG images.
Existing institution/manager image choices are reused unchanged.

## Verification

- Four widths × two languages for the holder selection/detail flow.
- Search, clear and no-result state; no-data state; null vs. zero; stable
  non-mutating ordering; phone expand/collapse; exact Guru history target.
- Selecting and switching a manager performs no save. Decision-source
  selection persists locally across manager switches until the existing
  decision workflow explicitly saves it.
- 14 dedicated tests; 289 total Flutter tests passed; analyzer/i18n passed.
- Release web build passed against the local backend.
- Browser tested Renaissance search and history navigation, NVDA ticker and
  cutoff retained; English/Chinese phone screenshots; no console errors.
- Paired before/final visual review and image paths: `design-qa.md`.

Implementation: `lib/investment_holders.dart`, integration in
`lib/investment_workflow.dart`, overview reuse in `lib/investment_research.dart`,
part registration in `lib/main.dart`, tests in
`test/investment_holders_test.dart`.

Production publishing requires a production-auth build and the normal release
gates; the currently served localhost build deliberately uses dev bypass.
