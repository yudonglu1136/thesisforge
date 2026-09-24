# Bilingual Coverage Audit

### 2026-09-24: Independent Strategy rule portfolios (production)

EN/ZH covers Quality Rank Top 10 and the Ackman quantitative proxy, curve toggles,
daily metrics, historical quarters, target-weight changes, raw score evidence,
original disclosure dates, unavailable states and exploratory-backtest limitations.
The existing Strategy builder remains the default. Production browser checks cover
both languages on desktop and a 390x844 viewport, including the holding-evidence
dialog. Fresh analyzer, i18n, production build and 60 performance tests pass.
Full Flutter has 588 passes and the same 32 failures reproduced on the prior
production source; these are not reported as passed. See
`strategy-rules-production-2026-09-24.md` for release identities and data boundaries.

### 2026-09-23: AI sector-quarter growth contributor logos

The existing AI overview heatmap now occupies a full row. Each quarter/sector
cell shows aggregate revenue growth, the leading positive dollar contributor's
existing company logo/ticker, and its contribution in percentage points. YoY and
unadjusted QoQ use their own comparable populations. EN/ZH tooltip evidence
covers current/base revenue, sector denominator, actual report ends, disclosure
dates, ties, missing comparison and no-positive-contributor states. Narrow
screens retain fixed sector labels while quarters scroll. No scoring or source
fact formula changed. See `ai-sector-contributors-2026-09-23.md` for verification
and release scope; unrelated whole-suite failures are not claimed as passes.

### 2026-09-12: Guru consensus read guide (local only)

EN/ZH now names the page as holdings and consensus, defines consensus as shared
holdings rather than unanimous conviction, and explains each Guru's reported-book
weight versus the all-reporting-Guru holder count. The matrix summary header
explicitly scopes counts to all reporting Gurus in the selected quarter, not the
selected columns. Tap/hover help covers row/column reading, disclosed share changes,
missing entries and fund-asset limitations. No data, filters or study charts changed.
527 Flutter tests, analyzer, bilingual audit, Ontology gates and both web builds
pass. Browser checked desktop and mobile layouts. No production deployment.

### 2026-09-12: Portfolio YTD, Position / Income and hover (local only)

EN/ZH covers YTD/data-year/partial-baseline labels, Position / Income and its
secondary grouping controls, dividend/bond/cash/substitute-income categories,
dated report coverage, positive-receipt versus net-income limitations, missing
history setup guidance, empty states, hover readouts and privacy-safe tooltips.
526 Flutter tests, the analyzer, bilingual audit, Ontology gates, 56 focused
portfolio backend tests, 41 transport/performance regressions and both builds
pass. See `docs/portfolio-income-ytd-2026-09-12.md`. No production deployment.

### 2026-09-11: English Guru holdings matrix with retained study (local only)

Implemented the selected screenshot as an English-first Guru page, while keeping
the original study shortlist, turnover/CAGR and turnover/Sharpe plots, all-profile
directory and chart/portrait inspection linkage. All new interface text also has
ZH translations: quarter/search/selection, concentration, weight/change modes,
pagination, source groups, valuation handoff, errors, unknown holdings and source
coverage. Canonical manager/company names remain unchanged. The same dated
disclosure APIs supply the matrix; no financial values from the mock were copied.

479 Flutter tests pass, including 12 new matrix/composition tests and 16 retained
study tests. Analyzer, i18n audit, ontology verification/tests, 19 focused read-model
tests, production build and local preview build pass. Browser verification covers
English at 1487x1058, 1280x720 and 390x844, Chinese at 390x844, actual historical
filing/stock navigation, filters and comparison linkage. No production deployment,
follow action, strategy run, or source-database mutation is part of this change.
See the 2026-09-11 acceptance section in `design-qa.md`.

### 2026-09-10: Discover / Guru study — selected Option 3 (local only)

EN/ZH covers the three-manager shortlist, inspecting/comparing states, period,
turnover/method/Sharpe filters, picker/search, quarter handoff, following, errors,
missing comparisons, and explicit simulation/turnover methodology. Original
manager names and CAGR/Sharpe identifiers remain canonical. Existing portraits
are reused; no financial values or source histories are fabricated.

453 full Flutter tests passed, including 13 focused study tests, late-response
invalidation, EN/ZH at 390px and 150% text. Analyzer, i18n audit, release preview
build and 63 focused Node tests passed. Browser checks cover both languages,
390x844 / 1280x720 / 1487x1058, chart selection, max-three limit, actual 2026-Q1
Li Lu holdings and the exact GOOGL research handoff. See the scoped Option 3
section in `design-qa.md`. This does not certify production or Strategy Lab.

### 2026-09-10: Prefilled private worksheets and account memory (local only)

EN/ZH covers sourced analyst starting assumptions, recovery/illustrative-default
disclosures, auto-save/pending/failure/retry/conflict states, source-change
restoration and preservation of legacy QA versions outside automatic defaults.
See `docs/personal-valuation-memory-2026-09-10.md`. No production deployment.

Date: 2026-08-30
Scope: Flutter application, standalone Ontology explorer, dynamic API labels, desktop and mobile layouts.

### 2026-09-10: Independent personal valuation (local only)

EN/ZH covers blank five-year user hypotheses for eligible earnings-only snapshots,
illustrative Ke/g disclosure, historical negative FCF, copy-first-year controls,
automatic recalculation, fixed before/after comparison and private saved versions.
411 full Flutter tests, 111 investment backend tests, analyzer, i18n audit and
release build passed. Actual AMZN edit flow checked in both languages at 390x844
and desktop. See `docs/personal-valuation-independent-2026-09-10.md` for model limits.

### 2026-09-10: Account-first Home (local only)

Home now shows the owner's broker portfolio, with explicit report dates, account
value, cash/borrowing, NAV history, daily versus cumulative Winners / Losers,
actual holdings and links to valuation/risk. EN/ZH covers missing-history states,
IBKR report requirements, range controls, owner-source errors and cumulative-P&L
fallback disclosure. No live/today claim is made for the one-date local snapshot.
All 408 Flutter tests passed; 8 Home tests include 390px EN/ZH at 120% text.
Analyzer, i18n audit, release build and 53 focused backend tests passed.
See `docs/personal-home-2026-09-10.md` for the data-quality boundary.

### 2026-09-10: Owner portfolio / Risk & SPY (local only)

EN/ZH copy covers private-source labels, report-vs-research dates, broker NAV,
marked leverage/negative cash/options warnings, simulated-vs-actual performance,
weighted SPY model comparisons, coverage/exclusions, growth/drawdown chart,
risk-free controls, formulas and masked IBKR connection onboarding. Company
tickers and standard financial acronyms remain canonical. The local owner copy
does not expose the legacy sample account through its account-management link.

19 focused portfolio widget tests passed, including EN/ZH at 390px with 150%
text. Full Flutter suite: 398 passed. Analyzer, i18n literal audit and release
preview build passed. API and browser acceptance use the verified owner report;
no claim of actual-account return history or production deployment is made.
Details: `docs/portfolio-owner-risk-2026-09-10.md`.

### 2026-09-10: Discover / Fundamentals workbench (local preview)

Replaced the sparse revenue-only list with four explicit research questions,
dated current/prior financial comparisons, counter-evidence prompts, eight-quarter
history, and precise valuation/financials handoff. EN/ZH includes definitions,
coverage, null/error/retry states, price comparison, filters, pagination and return
actions. Source company names, tickers and fiscal-period identifiers stay original.
Mobile uses two-column question tiles and a separate selected-company pane with
auto-scroll and a return action. Canonical stock marks are reused.

Eight new widget tests, 386 full Flutter tests and 129 related Node tests passed;
analyzer and i18n audit clean. Phone testing covers EN/ZH and 120% text. Browser
checks include the actual NVDA panel in both languages, desktop comparison,
and valuation round trip preserving the selected research screen. Local only.

### 2026-09-10: Discover / Value Flow (local preview)

Replaced the terminal-only placeholder with a native eight-stage AI value-chain explorer, exact company comparison, published valuation/quarterly evidence, and existing Guru avatars. EN/ZH copy covers all stage/role translations, loading/error/empty/missing states, filters, sort, coverage definitions and research-return controls. Original company/manager names and source identifiers remain source-original. Mobile Discover tabs wrap into two readable rows; company selection scrolls to evidence and offers a return-to-comparison action. Existing white MRVL/AMZN marks use a contrasting backdrop only in this surface.

Eight focused Flutter tests (including EN/ZH at 390px and 150% text); full Flutter suite 378 passed. Analyzer and bilingual audit passed. Browser acceptance includes desktop EN/ZH, mobile EN/ZH, stage change, global search, below-model filter, exact PLTR valuation navigation at 2026-08-28, preserved search on return, and mobile AMD detail. Dated API checks cover 2026-06-01 and 2026-08-28. No production release.

## Acceptance Contract

2026-09-09 Personal Valuation local-preview addendum: horizontal five-year
revenue/growth/parent-common-FCFE-margin worksheet, locked actuals, linked input
semantics, input-validation explanations, private hypothesis notes, named
immutable versions, save/reload states and post-DCF reconciliation. Financial
comparison now uses a full-width read-only table with percentage-point deltas
and observed historical percentile bars. English/Chinese tests cover desktop,
tablet, phone and large text; source quotes, symbols and numeric units retain
their original meaning. This is local backend persistence, not an AWS release.

2026-09-09 Research local-preview addendum: bilingual company switch/watch controls,
overview/model/financials/decision routes, dated range/report controls, latest changes,
guidance context, holder links, countercase prompts, method/version boundaries and
read-only decision states. Company/manager names, stored source quotes and model
formulas remain source-original. Both languages are covered at desktop/tablet/phone
sizes in `test/investment_research_test.dart`; this is not a production release.

2026-09-05 addendum: first-time visitors now default to English. Explicit
Chinese is represented as `lang=zh`, including legacy Ontology redirects.
The user requested `/research/isrg/` as a deliberately English-only public
case; it is outside the terminal's bilingual-content requirement. Its login
entry CTA is translated in both languages and identifies the case as English
in Chinese mode. The existing authenticated terminal remains bilingual.
New regression coverage: 75 Flutter tests; five standalone Ontology language
tests; public-case English-only, routing and data tests. Public case mobile
verification uses a real 390×844 embedded browser viewport because the browser
viewport-override capability did not change its top-level window dimensions.

- English mode contains no CJK UI copy. Company names, tickers, brand names, and standard financial acronyms are allowed.
- Chinese mode contains no untranslated interface copy. Company legal names, tickers, brand names, source titles, and standard financial acronyms may remain in their official form.
- Language choice survives navigation between the Flutter shell and `/ontology/` and is represented in the URL where required.
- Navigation, filters, buttons, charts, tables, cards, dialogs, tooltips, loading states, empty states, errors, and API-supplied labels use the same language.
- Desktop and 390px mobile layouts must expose a usable language control without overflow.

## Coverage Ledger

### 2026-09-10: Strategy Leverage replaces fourth-step Hedge (local)

- EN/ZH leverage presets/slider, fixed4% funding assumption, exposure examples,
  cash offset, disclosure reset, leverage risk, financing summary/ledger, chart
  legend, legacy-rule migration notice and nonpositive-equity failure state.
- 1x remains the default; saved leverage is owner-scoped. Options data and old
  hedge records are retained, but the new builder does not submit hedge rules.
- Full Flutter400 tests, focused backend51 tests, analyzer, bilingual audit and
  release build pass. Includes390px/150% text in both languages. Historical real
  data smoke and calculation definitions: `docs/strategy-leverage-2026-09-10.md`.
- Local only; not a production language or data-coverage release.

### 2026-09-10: Strategy Lab (local preview)

- EN/ZH coverage for Guru picker, Top N, price-premium filter, cash/redistribution,
  KMLM/DBMF allocation, date range/costs, explicit run/save, loading/retry, private
  saved versions, dirty results and blocked source states.
- Daily growth/drawdown legend and values, selected-range statistics, exposure
  strip, dated rebalance audit, exact-stock valuation navigation and original
  disclosure methodology are translated. Manager/ETF/company identifiers stay
  canonical. Historical source inputs remain separate from workspace research.
- Widget tests: desktop and 390×844 EN/ZH with 1.5× text; real browser mobile
  checks both languages, no error logs. Analyzer, bilingual audit and full
  370-test Flutter suite pass. This is not a deployed production release.

### 2026-09-09: Research company picker (local preview)

- Replaced the ticker-only modal with company-name/ticker search, canonical stock
  logos, current/recent labels, model dates, immediate exact-symbol selection,
  keyboard navigation and explicit loading/error/empty/retry states.
- English/Chinese controls and dismiss labels; current issuer names remain
  source-original. Directory is cutoff-filtered, not a recommendation or a
  certification of model quality. Recent items are session-local successful views.
- Phone layout, large text with keyboard insets, unchanged cutoff and unsaved
  scenario guards tested. Browser EN/ZH checks at 390×844 and desktop at 1487×1058.
- Local preview only; no user scenario writes and no production release.

### 2026-09-09: Discover research explorer (local preview)

Four rule-based collections, discovery filters/sorts, model coverage states,
evidence preview and return navigation use the shared bilingual helpers.
Fundamentals adds translated thresholds, search/reset and economic caveats.
Existing company names, ticker identifiers and official evidence retain their
source language. New widget coverage tests English and Chinese at 1487×1058,
1280×720 and 390×844. This entry is local verification, not production release.

### 2026-09-08: Confirmed connected workbench (current local Home)

- The confirmed reference is `exec-82f085f7-6688-4bf4-84f2-fb3909ae6757.png`; the editorial option below was mapped incorrectly and rejected. Home now links investor → filing → common-share holding → research and valuation.
- Bilingual controls cover the investor menu, filing/accession menu, search dialog, value/position tabs, position metric switches, source dialog, missing PIT versus transient error, and mobile Investor/Holdings/Research steps. Legal issuer/manager names, tickers and source URLs stay canonical.
- 208 Flutter tests (76 workflow) and 33 backend workflow tests passed. The existing repository literal audit passes; it does not scan every new part file, so populated widget tests and browser EN/ZH checks supply the new workbench coverage.
- 390×844 browser checks include Gavin/ALAB missing-research and position states, MSFT curve/metrics, Chinese saved actions and primary CTA. Compact desktop checked at 1280×720; wide reference at 1487×1058. Evidence in `output/home-workbench-20260908/` and current `design-qa.md`.
- Local implementation only. This does not certify full issuer coverage, production authentication or a deployed language release.

### 2026-09-08: Historical editorial Home (incorrectly mapped option; superseded)

- Replaced tutorial-like Home cards with a bilingual, source-backed filing brief: selected manager, current/prior disclosed shares, claim coverage caveats, and independent valuation example.
- Dynamic quarter labels, manager/example menus, loading/error/retry, disclosure/price/model dates, saved actions and compact tabs use the existing language helpers. Corporate-action language is explicitly translated; missing extraction is never labelled as zero/new buying.
- Full suite: 202 Flutter tests (70 workflow), 33 backend workflow tests. Full static analysis, bilingual audit and final private build passed. Browser checked English and Chinese at 390×844, including lower holding actions and saved-research labels.
- Actual comparison and mobile evidence: current editorial section in `design-qa.md`, screenshots 22–28 under `output/home-redesign-20260908/`. Local preview only; no production language release.

### 2026-09-08: Home first-use redesign (local only)

- Home now presents dated Guru holdings and a separately labelled valuation example before saved-research state. All new copy, search, date controls, compact switches, unavailable / retry states and rule warnings use the existing language helpers.
- Explicitly selected the workflow action formatter for saved Watch / Pass / Invest records; a name collision with the terminal formatter had left the initial Chinese footer untranslated. Final browser evidence shows 观察 / 放弃 / 投资.
- Added 12 Home regressions, including English / Chinese at 1487×1058, 1280×720 and 390×844. Final full Flutter suite: 195 passed; backend workflow suite: 33 passed. Targeted analysis and local web release build passed.
- Browser evidence under `output/home-redesign-20260908/` includes both languages, compact switching and a scrolled Chinese saved-research state. This is not a production language release or a new full Ontology audit.

### 2026-09-06: Admin last-sign-in portfolio cohorts (local only)

- Main Admin directory now shows registered/unregistered portfolio cohorts,
  independent latest-sign-in ordering, verified login versus activity time,
  unknown-login and unknown-registration states, timezone, search and refresh
  in English and Chinese. Desktop uses two columns; mobile stacks them.
- Nine new Dart/widget regressions cover both languages at 1280px and 390×844,
  ordering, cohort definitions, actions, empty states and bounded scrolling.
  Full Flutter suite: 131 passed; analyze and bilingual audit passed.
- These checks use synthetic local accounts, not a production browser session.
  See `admin-user-directory-2026-09-06.md`; not deployed.

### 2026-09-06: Missing valuation versus request failure (local only)

- The stock drawer distinguishes confirmed unpublished coverage, unavailable
  service and lost authorization in English and Chinese. Missing publication
  has no misleading Retry action; transient errors retain retry/recovery.
- Eight new language/viewport tests cover both states at 1280×720 and 390×844;
  another test checks that authorization loss clears displayed valuation data.
- 110 Flutter tests, analyze, i18n and production build passed locally. This
  does not attest to CRDO model coverage or a production deployment; see
  `crdo-valuation-gap-2026-09-06.md`.

### 2026-09-05: Guru stock valuation and shared issuer branding

- Added bilingual stock-research drawer/full-screen detail, footer actions,
  model/price dates, independent validation labels, missing-coverage retry,
  private-security tooltip and company-logo fallback. Market Lens keeps its
  language while opening and returning from inline research.
- `lib/stock_research.dart` is included in the same literal-guard audit as
  `lib/main.dart`. Regression tests cover EN/ZH at 1280×720 and 390×844.
- Ontology branding is decorative and preserves adjacent ticker/company text;
  app/style/i18n asset version is `20260905-2`.
- Local verification only; authenticated production integration and the full
  AWS universe are not certified by this addendum. See
  `guru-stock-research-2026-09-05.md` for evidence and limitations.

| Surface | Desktop ZH | Desktop EN | Mobile ZH | Mobile EN | Dynamic / hidden states | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Authentication and login | PASS | PASS | PASS | PASS | Provider, bypass, validation, error copy | PASS |
| Global header and navigation | PASS | PASS | PASS | PASS | Tooltips, account menu, refresh, contrast | PASS |
| Guru overview | PASS | PASS | PASS | PASS | Guru type, source, strategy tags, empty/error states | PASS |
| Guru simulation and backtest | PASS | PASS | PASS | PASS | Period controls, metrics, chart labels, warnings | PASS |
| Guru buys/sells and contribution | PASS | PASS | PASS | PASS | Activity types, dynamic ticker context, chart labels | PASS |
| Guru 13F history | PASS | PASS | PASS | PASS | Filing status, quarter labels, exposure states | PASS |
| Quarterly Market Lens | PASS | PASS | PASS | PASS | Common-quarter coverage, crowded holdings, reported adds/trims, ticker search, manager evidence, valuation and reported-change actions, no-data state | PASS |
| Ontology strategy view | PASS | PASS | PASS | PASS | Strategy names, descriptions, parameters, validation copy | PASS |
| Ontology decision history | PASS | PASS | PASS | PASS | Decision drawer, BUY/SELL, reason and risk labels | PASS |
| Ontology market map | PASS | PASS | PASS | PASS | Sector, industry, company modal, financial drivers | PASS |
| Ontology graph | PASS | PASS | PASS | PASS | Node labels, relationships, company dialog | PASS |
| Ontology ranking | PASS | PASS | PASS | PASS | Ranking labels, company detail, score components | PASS |
| Ontology methodology | PASS | PASS | PASS | PASS | Source names, model terms, risk and validation text | PASS |
| Valuation market map | PASS | PASS | PASS | PASS | Sector/industry taxonomy, filters, distribution bars | PASS |
| Valuation company research | PASS | PASS | PASS | PASS | PIT source, guidance, model methods, Q&A and errors | PASS |
| Portfolio cockpit | PASS | PASS | PASS | PASS | Connection status, NAV, allocation, risk and empty states | PASS |
| Portfolio dividends and analytics | PASS | PASS | PASS | PASS | Month labels, currencies, valuation status, notices | PASS |
| Admin health and user index | PASS | PASS | PASS | PASS | Job status, user status, search, empty/error states | PASS |
| Admin read-only portfolio detail | PASS | PASS | PASS | PASS | Selected-user detail and nested Portfolio surfaces | PASS |

## Admin recent sign-ins addition — 2026-09-06 (local verification)

- Added `AdminLoginActivityPanel` with bilingual loading, failure/retry, empty,
  search, pagination, unknown-login and device-timezone copy.
- Eight dedicated widget tests cover English and Chinese at 1280px and
  390x844, distinct sign-in/activity timestamps, missing values, search,
  response races, pagination and retry. No render overflow was observed.
- `npm run audit:i18n` passes. These are local widget/source checks, not a new
  production-browser attestation; this addition has not been deployed.

## Fixed Findings

| Finding | Fix |
| --- | --- |
| Independent Ontology page did not share the application language state | Added a standalone bidirectional translation layer, URL/local-storage state, and cross-module language links. |
| API-supplied labels could bypass static dictionaries | Added dynamic templates and exact mappings for sectors, industries, categories, strategies, companies, statuses, and financial-driver text. |
| English Ontology could expose Chinese after opening dialogs | Mutation-based localization now covers inserted nodes, attributes, dialog content, and asynchronously rendered values. |
| Chinese Ontology retained English taxonomy and signal labels | Added reverse exact mappings for the complete released sector/industry/security taxonomy and trading signals. |
| Mobile header could hide the language control in horizontal navigation | Added one fixed compact language button in the first header row and removed the duplicate mobile language segment below. |
| Decision replay and market detail could expand the mobile document width | Compressed timeline bars responsively and contained wide data tables, company controls, and dialogs within local scroll surfaces. |
| Six Ontology view tabs could overflow the desktop header at intermediate widths | Added stable two-row and three-row header layouts for 761–1540px viewports. |
| Reverse translation could mutate legal names containing a status token, such as `COMPASS` | Replaced raw substring rewrites with ASCII word-boundary matching and added a non-corruption regression assertion. |
| Browser cache could retain stale Ontology translations | Versioned Ontology CSS, application JavaScript, and translation assets as one release unit. |
| Admin nested Portfolio detail was not represented in language regression tests | Added an API-backed widget fixture and English zero-CJK assertion over the full rendered tree. |
| The unauthenticated shell used a fixed 520px panel and widened a 390px mobile document | Replaced the fixed width with a safe-area constrained layout, verified a 390px document width in a real browser, and added a widget regression assertion. |
| Quarterly crowding and activity cards had no bilingual drill-down state | Added a responsive Market Lens with translated tabs, metrics, explanations, caveats, search, manager evidence, empty states, and navigation actions; desktop and 390x844 widget tests guard both layouts. |

## Automated Gates

### 2026-09-09 quarterly earnings research

Added a localized fiscal-quarter selector, previous/next controls, recap,
guidance/Q&A tabs, source actions, missing-coverage/error/retry states and
explicit latest-versus-selected-quarter labels. Stored English/Chinese Q&A
is reused without online translation; missing translations are labeled as
source-language excerpts. Eight new Flutter tests cover bilingual 1280px and
390px workflows and race/error handling. Real browser checked English and
Chinese phone views, including expanded answers. Full Flutter suite: 297 pass;
analyzer and i18n audit pass. Local preview only; source coverage limitations
are recorded in `docs/research-earnings-calls-2026-09-09.md`.

### 2026-09-09 disclosed holder redesign

The Research overview and detailed ownership evidence now reuse existing
Guru portraits. The searchable roster, reported share counts/book weights,
selected disclosure, SEC action, Guru history navigation, decision attribution
and missing-data copy are bilingual. Widget flows cover English/Chinese at
1720, 1280, 1024 and 390px. Real-browser English and Chinese 390×844 detail
captures show no horizontal overflow. `npm run audit:i18n` and the full
289-test Flutter suite pass. This is local verification, not a deployment.

### 2026-09-09 personal terminal-edit repair

Ke/g bounds and invalid-input recovery now appear beside the editor in both
languages. Recalculating, timeout, request failure and retry copy use `w`/`label`;
invalid input never falls through to an English-only API error or workspace
reload. Terminal value, discounted terminal value, explicit PV, terminal share,
currency units and formula explanation are localized. Bilingual 390px regression
tests verify field focus, input preservation and valid-value recovery.

### 2026-09-09 four Discover research lenses

Localized card actions, distinct research questions/table columns, manager-side
rosters, reported share/weight/date labels, financial before/after comparisons,
revision endpoints, diligence caveats, missing-data states and Research/Valuation
actions through the existing `w(en, zh)` helper. Canonical manager names and
issuer identities remain source-original. Twenty-eight focused tests include all
four lenses at 1487, 1280 and 390px in English and Chinese. Real-browser English
and Chinese phone rosters and English phone growth table are visually verified.
The bilingual audit passes. Local preview only; no production release.

### 2026-09-09 horizontal quarterly research book

Replaced the hidden quarter dropdown with direct-select horizontal fiscal-quarter
cards, exact dated revenue/FCF previews, year jump, latest and strip-navigation
controls. Three reading stages, a compact financial comparison, model/diligence
panel, guidance/Q&A tabs and explicit valuation handoff use `w(en, zh)` throughout.
Original source excerpts and verified stored translations are preserved. Fourteen
focused tests cover desktop/phone EN/ZH, 1.5× text, cutoff identity, selection,
request races and no-write navigation; all 343 Flutter tests pass. Real browser
verified EN/ZH phone quarters and Q&A controls. Analyzer and i18n audit pass.
Local preview only; no production publication or backend/data changes.

### 2026-09-09 portfolio × valuation × Guru integration

Account-state, summary, currency grouping, positions, model-contribution,
concentration, stress, manager comparison, private-source and methodology copy
uses paired English/Chinese strings in `investment_portfolio.dart`. Raw issuer
and manager names remain source-original. Fourteen focused widget tests cover
all tabs in both languages at 390px and 1.5× text, exact drill-down actions,
request races, errors and private-source states. Full Flutter suite: 357 passed.
Real-account populated acceptance is pending; the development identity must not
be passed off as the user's online account. No production release in this turn.

### 2026-09-10 Strategy step-four Hedge

Hedge now sits after CTA, without a separate navigation tab. Type, coverage,
available duration, capital, risk assumptions, proxy warnings and output tables
use paired EN/ZH strings in `investment_strategy_hedge.dart`. Raw OCC identifiers
and issuer names remain source-original. The full Flutter suite passed 393 tests,
including step-four EN/ZH 390px layouts at 150% text, private rule saves, local
cache response races and explicit unhedged historical-curve labeling. Analyzer
and i18n audit passed. Local preview only; no production release.

### 2026-09-10 Discover steady-value screen

The third collection now screens sustained eight-quarter model-value progress,
not a large latest revision. Collection labels, stable-first sorting, threshold
chips, metric cards, quarter selector, exact value table, comparability rules and
replay/corporate-action caveats use EN/ZH strings in `investment_explorer.dart`,
`investment_discover_lenses.dart` and `investment_value_trend.dart`. Source ticker
names and fiscal labels remain original. Four-lens tests cover both languages
at desktop and 390px widths. See `docs/discover-steady-value-2026-09-10.md` for
metric formulas and read-only source QA. No production release.

### 2026-09-10 Growing-business quality controls

Growth-only, durable-ROIC and cash-backed presets; numeric thresholds; annual
window and passing-year selectors; optional cash/profit factors; coverage
funnel; annual evidence table; and pre-tax/denominator limitations use paired
EN/ZH strings in `investment_growth_quality.dart` and the Discover lens/list.
Issuer names and source identifiers remain original. Targeted tests cover both
languages, decimal/invalid input handling and desktop/390px research workflows.
Native browser checked real annual data and Chinese mobile controls. See
`docs/discover-growth-quality-2026-09-10.md`. Local preview only.

### 2026-09-10 Combined Fundamentals shortlist

Growth/profitability/cash-flow/ROIC controls, ALL/ANY logic, custom thresholds,
pass/missing reasons and Valuation/Financials/Guru-quarter navigation now use
paired EN/ZH copy. Manager identities/avatars and exact source dates are retained.
Reporting-quarter, historical-extract and unverified share-change limitations
are bilingual. New widget tests exercise both languages at 390px/120% text,
with in-session company and quarter restoration. See
`docs/fundamental-shortlist-2026-09-10.md`. Local preview only.

### 2026-09-10 Strategy filing-history boundary

The strategy failure surface now separates a pre-disclosure start from an
insufficient Top-N extract. EN/ZH copy states the first stored public date and
that dates were not changed; it no longer suggests reducing Top N to create
nonexistent historical filings. Paired copy, widget regression, analyze and
bilingual audit pass. No change to the strategy's economics or saved rules.

### 2026-09-11 Strategy full investment and historical holdings

The explicit eligible-subset full-investment policy, fixed CTA allocation,
zero-eligible blocker, concentration warning, snapshot navigation, allocation /
exposure distinction, excluded-book reasons and historical/public dates have
paired EN/ZH strings. Historical stock rows retain company logos and canonical
Guru portraits/names. Existing saved cash policies are not silently rewritten.
Frontend tests cover both languages at 390px and 150% text size, including
snapshot arrows, exclusion expansion and research navigation. Full Flutter
suite: 456 passing; analyze and bilingual literal audit pass. See
`docs/strategy-full-investment-2026-09-11.md`. Local preview only.

### 2026-09-11 Guru directory and linked portraits

Added paired EN/ZH directory headers, shared-search guidance, four sort modes,
comparison controls, selected-state labels, missing-simulation messages, plot /
directory counts and chart return links. All 29 catalog managers remain
browsable; 28 have comparable chart data at the verified cutoff. No absent
return is displayed as zero. The exact-quarter holdings entry stays bilingual.
Six layout variants cover 390/1000/1223px in both languages, with 150% mobile
text; 16 focused tests and all 459 Flutter tests pass. Actual browser portrait,
quarter and linked-chart behavior checked at desktop and 390px widths. See
`docs/guru-directory-2026-09-11.md`. Local preview only; no backend metric changes.

### 2026-09-11 Home history and P&L repair

Added paired EN/ZH NAV / realized P&L / P&L estimate chart controls, range-aware
amounts, selected-date details, explicit estimate/source boundaries, FIFO
ranking and revised IBKR history guidance. 11 focused Home tests and 462 full
Flutter tests passed, including 390px EN/ZH at 120% text. Actual private owner
history, not fixtures, backs local preview acceptance. See
`docs/portfolio-history-repair-2026-09-11.md`.

### 2026-09-11 One-click portfolio privacy

Home and connected Portfolio share bilingual privacy controls, retained browser
preference, percentage-only NAV / P&L curves and rankings, clear denominator
captions, unavailable-rate states, storage failure feedback, and a protected
research-notes shelf. Amounts, units and account labels are masked; rates and
weights remain visible. Twelve new tests include EN/ZH at 390px and 150% text;
all 491 Flutter tests, analyze, bilingual audit and build checks pass. See
`docs/portfolio-privacy-2026-09-11.md`. Local preview only.

### 2026-09-11 Owner holdings: valuation + Guru activity

Home and Portfolio holdings now share bilingual disclosed-quarter Guru activity:
holder counts, additions/new positions, reductions/exits, named portrait lists,
weights, share-change rates, filing dates and exact filing drilldowns. Partial,
unknown, no-match and security-conflict states are translated; manager names
remain official proper nouns. Valuation/financial navigation and amount privacy
remain intact. Focused 390px EN/ZH tests at 150% text scale and all 494 Flutter
tests pass. See `docs/portfolio-guru-integration-2026-09-11.md`.

### 2026-09-11 Backtest snapshots and filtering evidence

Added an always-visible results snapshot selector, Holdings & filters inspector,
paired EN/ZH exclusion reasons, decision prices/dates, saved-run premium limits,
redistribution explanations, source filings and separate unavailable-Guru counts.
Date browsing does not run/save or relabel historical evidence with current
controls. Mobile EN/ZH at 150% text is covered. See
`docs/strategy-snapshot-inspector-2026-09-11.md`. Local preview only.

### 2026-09-11 Strategy mix: independent factor configuration

Added paired EN/ZH factor switches, threshold inputs, observation/passing-year
selectors, enabled-factor ranking, Top N, empty-selection protection and saved-run
rule summaries. The existing four factors can be added/removed independently,
including single-factor strategies. Focused strategy widget tests cover English
and Chinese at 390px / 150% text; 35 tests pass, along with the bilingual audit.
See `docs/strategy-equity-mix-2026-09-11.md`. Local preview only.

### 2026-09-11 Independent CTA configuration

Paired EN/ZH CTA modes, calendar frequencies, editable trigger stages, minimum
target, tranche size, cooldown, validation, apply/cancel, completed-run CTA
weight chart, trade reasons and snapshot links. The dialog explicitly preserves
LanguageScope across its route. The 39 focused strategy widget tests pass,
including 390px / 150% text in both languages; targeted analysis and bilingual
audit pass. See `docs/strategy-cta-rules-2026-09-11.md`. Local preview only.

Final regression: full Flutter analysis and all 509 Flutter tests pass. Browser
verification exercised the English configuration, real backtest, CTA-weight
chart and event-to-snapshot link, then the Chinese snapshot and modal.

### 2026-09-22 Research quarterly statements

Added paired EN/ZH Annual / Quarterly controls and chart hover/tap amount,
YoY/QoQ, reporting/disclosure dates, missing-comparison, non-positive-base and
currency-change explanations. Frequency is shared by all three statements.
Focused tests pass in EN/ZH at desktop and 390px; live AMZN browser checks cover
both languages and mobile touch. Analysis, i18n audit and production build pass.
The full Flutter suite has 32 independently reproduced pre-existing failures
and no new failing test names; see `docs/research-quarterly-statements-2026-09-22.md`.

Run before release:

```bash
npm run audit:i18n
flutter analyze
flutter test
npm run verify:ontology-module
npm run test:ontology
npm run build
node scripts/verify-ontology-module.mjs --built
```

Browser verification must exercise both languages on desktop and 390x844 mobile viewports, including the unauthenticated shell, Ontology dialogs, and the Guru, Valuation, Portfolio, and Admin routes. A release is blocked by CJK copy in English mode, untranslated UI English in Chinese mode, a translation fallback warning, or a layout overflow.

## 2026-09-22: Active-manager sector detail

New sector dialog has EN/ZH headings, metrics, filters, paging, source-quality
warnings, error/retry and Research actions. The supplied sector/industry taxonomy
uses the shared bilingual dictionary. Desktop and 390px tests cover both modes;
actual browser checks cover the industry/stock/manager drill-down. The old
Ontology checklist above is historical only; that product remains retired.
See `docs/13f-sector-drilldown-2026-09-22.md` for coverage and verification limits.

### 2026-09-22 Sector visual refinement

Active-sector summary, company-logo cards, compact filters, expandable position
details and coverage/methodology labels have paired EN/ZH text. Real-data desktop
(1440×1000) and 390×844 mobile dialogs verified in both languages. Nine focused
Flutter tests pass; i18n audit, analysis and production build pass. Full Flutter
remains 568 passed / 32 pre-existing adjacent failures; no assertions removed.
See `docs/13f-sector-visual-polish-2026-09-22.md` for exact scope and checks.

### 2026-09-22 Fundamentals recovery and redesign

Paired EN/ZH search-first company browser, explicit sorting, compact metrics,
advanced thresholds, mobile research-focus selector, source explanations and
recoverable errors. Company research remains reachable without a model.
Real-data desktop and 390×844 flows reviewed in both languages; source dialogs,
search, company selection and optional valuation are exercised. The 29 focused
Fundamentals/explorer tests pass. Full Flutter has the same 32 pre-existing
adjacent failures, with no new failing names. See
`docs/fundamentals-recovery-redesign-2026-09-22.md` for data-runtime diagnosis,
scoped installation, release gates and production verification limitations.
