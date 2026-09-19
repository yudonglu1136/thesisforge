# Integrated Guru → Valuation → Observation workflow

## Scope and status

Local implementation on the existing Graphite Flutter workspace. No production deployment, Git push, valuation recalculation, financial-source import, or source-database mutation. Existing dirty worktree was preserved. The original terminal, manager workbench, backtest engines, and personal scenario calculations remain in place.

Preview: http://127.0.0.1:5184/?view=home&asOf=2026-08-28&lang=en&candidate=NVDA

## Delivered behavior

- Home and Guru discovery can start with shared holdings, reported additions, reported reductions, or a valuation-gap sort. Each candidate combines distinct-manager coverage, reported changes, published model gap and comparable model-node change.
- Selecting a ticker opens its actual price/value chart and latest disclosed operating metrics in the adjacent research track. The disclosure/financial date selector reloads only evidence available at that cutoff. The candidate-list date remains explicitly labeled.
- Management guidance excerpts show stored observation dates, speakers and source links. Published blended fair value is never relabeled as the standalone FCFE component. Unsupported personal-model routes retain the published chart, methods and evidence in read-only form.
- Save observation creates an immutable owner-scoped record, without requiring a DCF, investment decision, cash position, or order. Reviewing compares original/current price, model and fundamentals and counts new quarterly manager disclosures. Acknowledgment appends a new review; original evidence remains unchanged. Checks run when the workspace is opened, not through a new background monitor.
- Entering personal valuation preserves the candidate, research cutoff and return-to-list cutoff. Personal decisions may freeze server-verified discovery context; only explicitly selected managers are opted into decision monitoring.
- The Managers tab retains the existing manager/filing/claim history workflow. The legacy terminal remains available for complete backtests and its independent latest-data charts.
- Mobile uses a compact heading, horizontally scrollable research lenses and list/detail navigation; desktop keeps the ruled candidate list and linked research panel alongside the existing navigation.

## Data boundaries

The local 2026-08-28 snapshot exposes 27 eligible managers, 27 matching full current-quarter books, 573 common-share ticker candidates and 243 price/currency-comparable model rows. At 2026-06-01 it exposes 178 candidates, 105 comparable models, and historical extracts rather than complete historical books. These are local snapshot coverage measurements, not a claim of complete security/model coverage or a fresh market-data audit.

- Full books require exact accession, report date and public filing cutoff agreement. Otherwise the view uses the explicitly labeled historical extract.
- Claim aggregation uses exact CUSIP/common-share identity; one manager is counted once per ticker. Options are excluded. Renaissance remains available in manager research but excluded from the shared-ownership crowding universe.
- Missing model, missing price, unknown currency and absent historical observation remain missing, never zero or another ticker. A missing extract is not an exit.
- Historical manager evidence is limited to the latest observed report quarter at the selected cutoff; stale older-quarter observations are not passed off as current holdings.
- The price is a comparison input; this work does not alter valuation-engine assumptions. Model-version, formula or currency changes disable valuation-change percentages.
- Source SQLite is opened read-only; investment events remain in the separate existing local `decisions.sqlite` with append-only triggers and owner isolation.

## Verification

- `flutter analyze`: no issues.
- `flutter test --reporter expanded`: **222/222 passed**, including 14 new integrated-flow widget tests and retained manager, valuation, portfolio, admin and identity tests.
- `node --test server/investmentOpportunities.test.js server/investmentWorkflow.test.js`: **44/44 passed**. Eleven new tests cover exact claims, historical cutoff, amendments, missing models/weights, cache invalidation and isolation, durable/idempotent/owner-scoped watches, changed-method guard, review acknowledgment and independently verified decision context.
- `npm run test:performance`: **41/41 passed**.
- `npm run audit:i18n`: passed. Official evidence quotes are preserved in their source language.
- `git diff --check`: passed.
- Flutter release preview build: passed; local authentication bypass artifact, **not suitable for production**.

Browser acceptance uses the Codex in-app browser, actual local APIs and the isolated local ledger: select GOOGL/AMZN/NVDA; replay AMZN at 2026-05-15; save observation; compare at 2026-08-28; acknowledge; reload; expand guidance; enter valuation and return; phone list/detail and desktop layouts. The test observation is labeled AMZN, as of 2026-05-15, in the local preview ledger only.

### Performance observations (not a production benchmark)

Bounded scalar SQL extraction and an invalidation-aware four-key read cache avoid repeatedly parsing the entire source universe. On this machine, one cold post-change run took 2,549 ms for 573 candidates; its immediate in-process cached repeat took 2 ms. Four already-warm HTTP requests took 37 / 11 / 10 / 11 ms and returned `private, no-store`. These are diagnostic samples, not a statistically controlled before/after claim; cold-cache latency still needs production-scale measurement before release.

## Files

- New read model and immutable observation flow: `server/investmentOpportunities.js`.
- Existing authenticated route/service integration: `server/investmentRoutes.js`, `server/investmentService.js`.
- Integrated view: `lib/investment_opportunities.dart`; existing Home, Discover, research and navigation parts updated in place.
- Tests: `server/investmentOpportunities.test.js`, `test/investment_opportunities_test.dart`, retained manager test helpers.
- Browser evidence: `output/integrated-guru-valuation-20260908/`.

## Remaining release work

This is a verified local workflow, not a new production release or a completed coverage expansion. Missing company models/full historical filings remain explicit. Unsupported personal DCF routes remain read-only. AWS/Vercel authentication, event-store migration, operational scale, complete-history coverage, and deployment approval remain separate release work. No model output has been invented to make this UI appear complete.
