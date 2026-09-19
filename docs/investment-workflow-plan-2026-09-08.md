# Investment workflow — local implementation plan

## Scope and evidence

Existing app was run locally from `trunk` 730dc21 with an isolated copy of the
September 5 production database. Baseline captures are private under
`output/investment-workflow-20260908/before-{valuation,company}.png`.

1. Entry: Valuation opens the whole-market map before the selected company.
2. Research: PIT curves and inputs exist; published blend and standalone DCF
   must remain distinct. Existing audit badges must not be upgraded by this work.
3. Decision: no persisted user scenario/decision/review chain exists.
4. Portfolio: existing broker connections are useful, but do not preserve the
   investment assumptions at entry. No standalone CTA engine was found.

## Target journey

Home attention → deterministic discovery → company Research → editable
scenario / reverse valuation → explicit Watch, Pass or Invest → immutable
decision → Portfolio → next PIT period → Then vs Now → Maintain or Change.

User decisions are research records, never broker orders. Historical replay is
labelled retrospective; reconstructed PIT inputs do not prove a live alert.

## Files / boundaries

- `server/investmentMath.js`: pure, versioned calculations; reuse existing FCFE
  discount kernel; validate nulls, currencies, dates and assumptions.
- `server/investmentSource.js`: read-only adapter over existing PIT model runs,
  price observations and public Guru disclosure history. No data refresh.
- `server/investmentStore.js`: separate append-only, owner-scoped SQLite ledger.
- `server/investmentRoutes.js`: authenticated API and explicit action boundaries.
- `lib/investment_workflow.dart`: existing Flutter design tokens/components,
  Home / Research / Discover / Portfolio / Strategies workflow.
- Existing entry and stock drawer: opt-in workflow navigation, legacy retained.
- Tests: arithmetic, PIT, source lineage, scenario/snapshot immutability,
  account isolation, persistence/restart, review rules, Guru and portfolio math.

Feature is preview-gated. No production DB migration, data release, refresh,
AI call, broker write, automatic assumption change or automatic trade.
First complete issuer: ISRG; independent second journey: MSFT.
