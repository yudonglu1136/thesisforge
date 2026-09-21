pyenv: cannot rehash: /Users/yudonglu/.pyenv/shims isn't writable
# ThesisForge — Graphite workspace QA

## Current acceptance: split-safe 13F institutional value history — 2026-09-21

Final result: **passed**.

Scope: correct the selected-stock ownership history without redesigning the
accepted 13F Insights page. Quarter-to-quarter bars must compare aggregate
reported institutional value, not raw share counts, so a stock split cannot
create a false economic jump. The amber series remains reported institutional
value as a percentage of company market capitalization.

### Visual evidence

- Reported share-based state:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-cf1c6548-30af-45c1-905e-2f26abd45745.png`.
- Browser-rendered implementation:
  `/private/tmp/thesisforge-13f-amount-history.jpg`.
- Both images were opened and inspected together. The accepted render retains
  the existing two-chart hierarchy and interaction model, but the right chart
  now identifies the teal bars as `Amount`, shows a money-scaled left axis and
  reports the latest PIT value in the card header.

### Findings and resolution

- [Resolved P1] Aggregate shares are not comparable through splits. The teal
  history series now uses the quarter's aggregate 13F reported amount
  (`currentValueM`) and formats its axis and tooltip in USD millions, billions
  or trillions.
- [Resolved P1] Existing production sidecars do not yet carry the new amount
  column. The server enriches only the requested security from the canonical
  PIT snapshots, while the append-only artifact builder adds and backfills the
  column by the existing natural key. No duplicate snapshot or holding rows are
  inserted.
- [Resolved P2] Compatibility enrichment initially re-read compressed history
  for every security. A bounded, amount-only snapshot index now reuses those
  values without retaining every full payload. On the real 20-quarter artifact,
  the first compatibility read was about 0.38 seconds, the next distinct stocks
  were about 3–4ms and a repeated stock was below 1ms after warm-up.
- The title, subtitle, legend and hover labels consistently say institutional
  value/amount. This acceptance supersedes earlier QA wording that described
  the teal ownership-history bars as raw reported shares.
- No remaining P0/P1/P2 issue in the requested flow.

### Verification

- Browser direct-load verification rendered NVDA with 20 PIT quarters,
  `$3.3T · 69.2%` in the header, `Amount` in the legend, and dollar y-axis
  labels. The page loaded without a refresh or an intermediate stock click.
- Server and artifact focused tests: **10 passed**. Flutter 13F suite:
  **16 passed**. `flutter analyze`: no issues. Production Flutter build: passed.

## Current acceptance: Portfolio IBKR sync, dividend views and legacy-route retirement — 2026-09-21

Final result: **passed**.

Scope: keep the accepted Snowball-inspired Portfolio hierarchy while completing
the missing operational layer. The new ThesisForge Portfolio now owns IBKR
connection management, explicit refresh, daily per-user sync, and broker-
reported dividend/interest allocation. No Portfolio action may return users to
the retired Guru Intelligence interface.

### Visual evidence

- Reported icon and control defects:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-115315d8-b139-4b82-a00c-2dc35584ce72.png`
  and
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-6639ed4c-51e3-424d-be92-eb629efcd47a.png`.
- Retired-interface reference:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-33903e4f-884e-40fa-80bc-37803b828681.png`.
- Browser-rendered verification at 1600x1000 confirmed that legacy
  `?view=portfolio` bookmarks render the new Portfolio desk, the old-terminal
  launcher is absent, the signed-out state remains intentionally private, and
  the browser console has no warnings or errors.
- Synthetic broker fixtures were used only in widget tests to verify the
  authenticated account cards and allocation controls. No sample holdings were
  added to the application.

### Findings and resolution

- [Resolved P1] Account value and realized P&L used icon glyphs that compiled
  to empty boxes in the web bundle. Both now use Material glyphs already
  exercised elsewhere in the app and have explicit widget assertions.
- [Resolved P1] Position/Income and Holdings/Sectors wrapped into two unrelated
  rows. All four choices now form one horizontally scrollable control rail;
  the labels change coherently between Holdings/Sectors and Income
  sources/Income types.
- [Resolved P1] “Income” was ambiguous. It is now “Dividends & interest” and is
  backed only by dated IBKR Cash Transactions. Dividend, bond-interest and
  cash-interest receipts retain their category, instrument, report period and
  transaction-date reported FX. Missing report sections remain unavailable;
  values are never estimated from yield data.
- [Resolved P1] Portfolio management navigated to the retired product. The new
  page now contains an in-place IBKR connection dialog and a distinct Sync now
  action. Legacy `portfolio` and `guru` bookmarks migrate to the new Portfolio
  and Discover routes, and all visible old-terminal launchers are removed.
- [Resolved P1] The scheduled NAV recorder used a process-wide legacy identity.
  It now enumerates only configured production users, calls the same
  authenticated per-user loader as Sync now, captures NAV into that user's
  isolated database, clears only that user's cache, and logs aggregate counts
  without PII. The default cadence is once per 24 hours.
- [Resolved P2] Sync success and degraded/stale outcomes were invisible. The
  new page preserves the last saved report, presents an explicit result notice,
  and never replaces it with an incomplete refresh.
- No remaining P0/P1/P2 issue in the requested flow.

### Interaction, responsive and verification checks

- The four allocation controls share one y-position at desktop width and stay
  available through horizontal scrolling at 390px with 150% text scaling.
- New-page connection management and explicit sync were verified without a
  legacy callback. The summary icons, exact income slices, income provenance,
  privacy mode and portfolio reload path remain covered.
- Flutter focused suite: **46 passed**. Node portfolio sync/income/cache suite:
  **17 passed**; the localhost HTTP test also passed outside the restricted
  socket sandbox. Launch-prep suite: **32 passed**. `flutter analyze`: no
  issues. Production Flutter build: passed with workflow marker verified.

## Current acceptance: 13F history loading, switching and hover — 2026-09-21

Final result: **passed**.

Scope: repair the existing all-institution 13F stock-detail flow without
redesigning it. A stock named in the URL or selected in the table must show its
own historical institution-count and ownership charts immediately; switching
stocks must not require a refresh. Both charts must expose exact quarterly
values on mouse hover and touch inspection.

### Visual evidence

- Reported broken state:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-6909dc64-2450-4784-a35d-d3e136fa9e6b.png`
  (GOOGL selected while both charts incorrectly showed no trend).
- Browser-rendered implementation:
  `/private/tmp/thesisforge-13f-hover-verified.png` (2048x1100 pixels).
- The two images were opened and inspected together. The accepted render keeps
  the established Graphite hierarchy and compact two-column desktop layout,
  now showing all eight available GOOGL quarterly observations. The ownership
  tooltip displays quarter, aggregate reported shares and percentage of shares
  outstanding; the institution tooltip displays quarter and exact filer count.

### Findings and resolution

- [Resolved P1] The summary endpoint implicitly preloaded MSFT while the UI could
  highlight GOOGL from URL state. The response now declares `selectedTicker`,
  and the client reconciles URL, response and row availability atomically.
- [Resolved P1] A late summary request could replace a detail fetched by a newer
  stock click. Detail responses are now keyed by cutoff, quarter and ticker,
  cached independently, merged without changing selection, and protected from
  stale request races.
- [Resolved P1] Empty detail was presented as insufficient history while the
  request was still in flight. The detail area now presents an explicit compact
  loading state and only shows the insufficient-history copy for real data gaps.
- [Resolved P2] History canvases exposed no inspection values. Both charts now
  support mouse hover, tap and drag, with a vertical guide, emphasized points
  and a bounded value tooltip.
- [Resolved P1] Every stock click previously decompressed and scanned all eight
  full-universe quarterly payloads. The backend now builds one bounded history
  index per visible snapshot set and reuses it across securities.
- No remaining P0/P1/P2 issue in the requested flow.

### Verification and performance

- Direct-load browser check: a GOOGL URL rendered GOOGL charts without a click
  or refresh. AMZN then loaded from the table in the same page and retained a
  complete history. Browser console: no warnings or errors.
- Hover QA: institution history showed `2025/Q3 · 5,619 filers`; ownership
  history showed `2024/Q4 · 7.87B shares · 64.52% outstanding`.
- Real artifact benchmark (8 quarters): repeated uncached per-stock processing
  was about 1.4 seconds. After the one-time history index, GOOGL, AMZN, NVDA and
  MSFT detail generation measured 30–48ms directly; warm local HTTP responses
  measured below 3ms.
- Server focused tests: **6 passed**. Flutter focused tests: **16 passed**.
  `flutter analyze`: no issues.

## Current acceptance: 13F stock ownership history and dual rankings — 2026-09-20

final result: passed

Scope: extend the existing all-institution 13F Insights stock view without
changing its visual system. The selected stock now leads with its historical
holder count and institutional ownership, while the institution leaderboard is
deliberately placed after those trends. Stock ranking can switch independently
between aggregate reported shares and reporting-institution count.

### Visual evidence

- Source state:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-f11667ba-45d1-4824-8ae7-20dc453fdb04.png`
  (2666x1066 pixels; pre-change desktop view).
- Browser-rendered implementation:
  `/private/tmp/thesisforge-13f-insights-final.png` (1600x1000 pixels).
- Both images were opened and inspected together. The accepted implementation
  keeps the established Graphite palette and existing information density, but
  changes the decision order to ranking controls -> selected security summary
  -> two historical charts -> institution ranking.

### Findings and resolution

- [Resolved P1] The stock table had only one implicit ranking. Two explicit
  controls now rank by distinct 13F institution count or aggregate reported
  shares; the URL persists the non-default selection.
- [Resolved P1] Institution rows previously occupied the selected-stock detail
  before historical context. The detail now shows institution-count history
  and aggregate reported shares plus ownership percentage first, with the
  institution ranking below.
- [Resolved P1] Ownership history did not exist in the snapshot contract. The
  append-only quarterly artifact now carries point-in-time basic shares
  outstanding using only fundamentals available by each 13F cutoff. The UI
  labels the denominator as shares outstanding rather than claiming free-float
  coverage.
- [Resolved P2] The institution list was fixed and short. Its visible limit is
  now selectable as Top 8, Top 20 or Top 50 and is retained in URL state.
- [Resolved P2] The two ownership series could visually overlap when normalized
  trends were similar. Aggregate shares now use teal columns and ownership
  percentage uses an amber line with an explicit legend.
- [Resolved P2] Desktop table columns and the two history cards were tightened
  for the 1280px breakpoint; compact layouts stack the charts and keep ranking
  values readable.
- No remaining P0/P1/P2 issue in the requested flow.

### Interaction, data and verification checks

- Browser interaction verified both ranking dimensions and Top 8/20/50 menu
  states. The accepted MSFT detail shows eight quarterly snapshots ending at
  6,231 filers, 5.49B reported shares and 73.9% of shares outstanding.
- History is clipped to the selected report quarter, so later snapshots cannot
  leak into a historical view. Compressed v2 snapshots are append-only and a
  same-input replay inserted zero rows.
- Server tests: **5 passed**. Flutter focused tests: **16 passed**.
  `flutter analyze`: no issues. Fact OS storage audit: passed with zero
  byte-identical raw duplicates and zero GC-eligible files.
- The broader repository storage-layout audit still flags pre-existing retired
  sibling project directories outside this repository; this change created no
  sibling project or duplicate database.

## Current acceptance: portfolio detail and model-structure table — 2026-09-20

final result: passed

Scope: simplify the main `?view=portfolio` page around the user's actual
decision flow. The supplied Snowball screenshot is used only for its
quiet, flat and highly scannable holdings-table hierarchy. ThesisForge keeps
its own Graphite shell, broker-backed NAV, interactive allocation views,
privacy mode and published valuation methodology. Snowball's dividend rating
is deliberately not copied.

### Visual evidence

- Source visual truth:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-7d9f0266-8715-4a50-9526-7386060695ec.png`
  (3016x1530 pixels; portfolio-table reference).
- Widget-rendered implementation:
  `/private/tmp/thesisforge-portfolio-detail.png` (1511x1000 pixels).
- Normalized side-by-side comparison:
  `/private/tmp/thesisforge-portfolio-detail-comparison.png` (3022x1000
  pixels), opened and inspected together. Flutter's widget renderer uses the
  Ahem fallback font, so the image verifies hierarchy, density, alignment,
  chart/table balance and responsive constraints; the runtime keeps the app's
  existing typography.
- Browser runtime check and final visual acceptance:
  `http://127.0.0.1:5174/?view=portfolio&asOf=2026-09-18&lang=en` rendered
  the accepted main route with the NAV panel and interactive allocation ring
  first, followed by the flat model-structure table. The signed-out local
  preview correctly labels its illustrative fallback as sample data; it was
  used for route, layout and interaction checks only. Hovering a donut segment
  replaced the center total with the exact ticker, weight and value.

### Findings and comparison history

- [Resolved P1] The prior detail view scattered composition and valuation
  across multiple cards before users could inspect their positions. The new
  hierarchy is NAV/P&L plus the interactive allocation donut first, followed
  immediately by one flat holdings table.
- [Resolved P1] A generic third-party-style rating would not describe the
  ThesisForge model. The table now exposes each company's actual backend
  `modelRoute`, published fair value and model/price gap.
- [Resolved P1] “Current → model” now compares each covered position's weight
  with its weight after revaluing the same covered sleeve to published fair
  values. The UI explicitly states that this is not a target allocation,
  score, or expected return; missing models remain missing rather than zero.
- [Resolved P2] The first pass left the visual hero too tall. The detail NAV
  plot and donut were compacted while retaining all controls, hover/tap states,
  explanations and research links, allowing the table header to enter the
  first desktop viewport.
- [Resolved P2] The sort selector could overflow on narrow or enlarged-text
  layouts. It now expands within its bounded field and stacks below search at
  compact widths.
- [Resolved P2] The first main-route render exposed an 8px overflow in the
  `Current → model` column at 1280px. Header and cell now share a fixed 124px
  width inside the horizontal table scroller; the browser rerender is clean.
- No remaining P0/P1/P2 finding. Existing security logos and app assets are
  reused; no reference asset was approximated.

### Interaction, responsive and verification checks

- Position/Income, Holdings/Sectors, income type/source, donut hover/tap,
  privacy mode, NAV ranges, holding search, sorting, ticker drilldown and the
  existing Risk/Guru tabs remain available.
- Desktop uses a sortable horizontal DataTable; compact and enlarged-text
  layouts switch to stacked holding rows instead of clipping columns.
- Focused portfolio suite: **55 tests passed**. Portfolio/valuation server
  suite: **28 tests passed**. `flutter analyze`: no issues. Production
  `npm run build`: passed and the compiled workflow marker was verified.

## Current acceptance: Snowball-inspired personal portfolio home — 2026-09-20

Final result: **passed**.

Scope: redesign only the authenticated personal-portfolio landing surface. The
Snowball reference supplies the information hierarchy—four summary metrics,
allocation chart beside a compact breakdown table, then performance and
gainers/losers—not its brand, purple palette, sample values, or navigation.
ThesisForge keeps its Graphite shell, teal semantics, real broker-backed fields,
privacy mode, valuation links and portfolio-history methodology.

### Visual evidence

- Source visual truth:
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-1d308e4f-c5c4-4700-a2b0-ab8a128451a7.png`
  (3022x1562 pixels; 1511x781 CSS-equivalent desktop frame) and
  `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-b533d07c-68a8-4a6a-ae09-ce1efbc8dd05.png`
  (2878x972 pixels; lower-page movers reference).
- Widget-rendered implementation:
  `/private/tmp/thesisforge-home-redesign.png` (1511x781 pixels).
- Same-input comparison:
  `/private/tmp/thesisforge-home-comparison.png` (3022x781 pixels), with the
  reference and implementation normalized to the same viewport and opened
  together. Flutter's test renderer uses the Ahem fallback font, so the image
  verifies layout, density and hierarchy; browser/runtime typography remains
  the app's existing family.
- Browser shell check: 1511x781 at
  `http://127.0.0.1:5174/?view=home&asOf=2026-09-18&lang=en` with no console
  errors. The local signed-out state correctly withheld private holdings, so
  synthetic broker fixtures were used only for the widget-rendered visual and
  interaction checks; no sample data was added to the application.

### Findings and comparison history

- [Resolved P1] The old landing page presented the NAV chart before explaining
  portfolio composition and split related information across several distant
  panels. The accepted hierarchy now places four scan-friendly account metrics
  first, then one allocation workbench with an interactive donut and top-position
  table, followed by the value/P&L curve and contribution movers.
- [Resolved P2] The first metric card carried too much saturated accent color.
  All metric cards now share the same quiet panel surface; accent is limited to
  the icon and border so account value is prominent without becoming a banner.
- [Resolved P2] The P&L methodology disclosure read like a loose warning line.
  It is now a compact information strip with concise bilingual copy.
- [Resolved P2] Gainers and losers were mixed in one dense list. They are now
  paired Snowball-style cards with consistent icons, spacing, signed values and
  existing Day/Open/Realized selectors.
- No remaining P0/P1/P2 finding. Existing logos/assets are reused; no image was
  approximated. Copy remains materially different from the reference and names
  the actual ThesisForge data semantics.

### Interaction, responsive and runtime checks

- The donut's Position/Income, Holdings/Sectors and income type/source views,
  legend selection, ticker navigation and hover/tap state remain covered by the
  existing portfolio visual tests.
- YTD/range inspection, NAV/P&L modes, privacy persistence and percentage-only
  chart behavior remain covered. Focused result: **39 tests passed**.
- English and Chinese 390x844 layouts at 150% text scale passed without overflow.
- `flutter analyze`: no issues. Production `npm run build`: passed; compiled
  workflow marker verified.

## Current acceptance: all-institution 13F Insights — 2026-09-20

Final result: **passed**.

Scope: replace Discover / Opportunities with an institutional 13F movement
radar built from every covered Sharadar SF3 filer. Guru selections remain an
independent tab and do not alter the rankings. No source facts were rewritten.

### Visual evidence

- Source visual truth: `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-31152522-d626-45ee-a257-bfc9c75bf1f5.png`
  (2762x1642 pixels, desktop concept).
- Browser implementation: `output/13f-insights-20260920/13f-insights-desktop-1440.png`
  (1440x1000 pixels) and
  `output/13f-insights-20260920/13f-insights-mobile-390.png` (390x844 pixels).
- Same-input comparison:
  `output/13f-insights-20260920/13f-insights-comparison.png` (3122x1000 pixels),
  source and implementation normalized to 1000px height and opened together.
- State: English, dark Graphite theme, 2026/Q2, increased positions, MSFT
  detail, public cutoff 2026-09-18. Desktop and 390px mobile states were both
  browser-rendered. The desktop concept and implementation use different crop
  densities, so comparison focused on hierarchy and interaction rather than
  false pixel precision.
- Focused comparison covered the four action cards, stock ranking, selected
  security summary and reporting-institution detail. A separate mobile capture
  verified the title, tabs, full-universe disclosure, quarter coverage, card
  rail and search controls without clipped persistent navigation.

### Findings and comparison history

- [Resolved P1] The first rendered stock detail followed the generic holder
  ordering (GOOGL) while the active increased ranking began with MSFT. The API
  now selects the largest increased-position count by default and the client
  preserves the returned bounded detail key. Post-fix browser evidence shows
  MSFT in both the first list row and detail panel.
- [Resolved P1] Opening 13F Insights still started the retired Opportunities
  and Guru-discovery reads, delaying first content and exposing an unrelated
  disclosure error. Route-aware loading now requests only 13F Insights on this
  tab; Guru and fundamentals data load only after their tabs are selected.
- [Resolved P2] Switching among new/increased/reduced/exited retained the prior
  ticker. Each card now selects and lazily loads its own first-ranked stock.
  Browser verification: New positions -> HONA and URL state
  `insightAction=new&insightTicker=HONA`.
- No remaining P0/P1/P2 finding. Fonts/typography reuse the established app
  family and weights; spacing and card rhythm remain consistent with the
  Graphite shell; teal/amber semantic colors preserve contrast; existing
  company logo assets are used rather than approximations; copy explicitly
  states the full-filer scope, split adjustment, delayed disclosure and lack of
  trade-date/price inference.

### Interaction and runtime checks

- Quarter selector, four action cards, stock/institution views, search, ranked
  stock selection and lazy detail fetch were exercised in the in-app browser.
- Institution view search returned BLACKROCK INC. No browser console errors or
  warnings remained in the accepted state.
- Clean local first visit reached the populated all-institution workbench in
  about 3.3 seconds in a Flutter debug build. This is local evidence, not a
  production-latency claim.
- Responsive widget coverage passed at 1487x1058, 1280x720 and 390x844 in both
  languages. No focused region required an additional crop after the desktop
  and mobile captures because all critical labels and selected-row figures were
  legible in those captures.

Final result: **passed**.

## Current acceptance: English Guru holdings + preserved study tools — 2026-09-11

Final result: **passed**.

Scope: implement the selected holdings-matrix reference in English within the
existing Discover / Guru page, while keeping the original study shortlist,
turnover/CAGR and turnover/Sharpe charts, full directory and portrait/point
selection links. Local preview only; no deployment, source-data mutation,
backtest execution or implicit follow/save action.

### Visual references and final comparison

- Primary reference: `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-45db7247-1e5c-4cdf-a204-5f630277ecc7.png`.
- Preserved-function reference: `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-b3722372-e076-4146-9990-d1c5b2e3b2a9.png`.
- Primary reference and final render opened together in the same comparison
  input at 1487x1058. Secondary reference and the one-Andreas shortlist/chart
  render also compared together. Existing Graphite tokens, native portraits,
  company logos and shell are reused; illustrative reference data is not copied.
- Final captures: `output/guru-holdings-20260911/desktop-final.png`,
  `style-final.png`, `chart-linked-directory.png`, `tablet-en.png` (1280x720),
  `mobile-top.png`, `mobile-table.png`, and `mobile-zh.png` (390x844).
- Composition preserves the left selection rail, quarterly matrix with portrait
  columns and all-Guru stock totals, followed by selected-stock valuation and
  new/add versus reduce/exit groups. Style & performance remains on this page,
  reachable through the rail link; the full directory remains below both charts.

### Resolved findings and interaction checks

- Selected Gurus appear first in the rail, in selection order. Independent study
  selection is preserved when holdings filters change.
- Four comparison columns at the reference width, three at narrower desktop
  widths; mobile provides horizontal matrix scrolling. No render overflow at
  390px, including the 150% text-scale regression test.
- Quarter switching, holding-weight/share-change modes, concentration >=10%,
  company search, sorting and both manager/stock pagination are wired to data.
- Browser verified: Q1 selection -> Li Lu portrait -> report 2026-03-31 filed
  2026-05-15; AMZN selection -> Valuation & financials -> AMZN valuation.
  Missing filings are explicit and never silently substituted with the latest.
- Browser verified: Andreas chart point highlights his directory entry; the
  Add a Guru picker produces the one-Andreas shortlist with both chart markers
  and the existing quarterly research action intact.
- English content checked; Chinese remains supported through the language
  switch. Final browser error log is empty.

### Data and verification bounds

- Existing read-only APIs supply all figures. There are 29 profiles, 27 managers
  in this disclosure view, and 28 comparable plotted simulations; coverage is
  labelled. Missing holdings are not zero or inferred exits. Reported share
  changes are not verified trades or corporate-action-adjusted changes.
- Price/model dates remain separate. GOOGL's displayed 2026-09-10 price is
  USD 332.60; its model is dated 2026-07-23. Retained study comparison history
  ends on 2026-08-31 and is explicitly labelled; this UI task did not refresh it.
- Full Flutter suite: **479 passed**, including 12 new holdings tests and the
  16 existing study tests. Focused workflow suite: 76 passed.
- Flutter analyze and i18n audit passed. Ontology module verification passed;
  ontology tests: Python 3 and Node 22 passed. Read-model Node tests: 19 passed.
- Both local release preview and production build passed. Logs are under
  `output/guru-holdings-20260911/`. No production deployment was performed.
- No unresolved P0/P1/P2 issue in this request's scope. Long legal firm names
  are intentionally ellipsized in compact headers; portrait links retain access
  to the full profile. Earlier acceptance records below are historical.

## Archived acceptance: Discover / Guru study — Option 3 — 2026-09-10

Scope: implement the user's selected third design inside the existing Managers
page. Preserve the original quarterly holdings → exact-stock valuation workflow,
canonical portraits, shared Graphite shell and authenticated per-user following.
No production release, strategy execution, source-database mutation or auto-follow.

### Visual source and comparison record

- Source: `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-3f69db33-70ec-4f2f-89d2-ea481ed58e79.png`.
- Reference and rendered captures were opened together in the same comparison
  input on passes 1, 2 and final. Reference/desktop viewport: 1487x1058 CSS pixels,
  effective 1:1 density; English, common history, Bill Ackman inspecting / Li Lu
  comparing, 2026-Q2 holdings, cutoff 2026-09-10 (pass 1 used 2026-08-28).
- Raw browser captures: `output/guru-study-qa-20260910/desktop-pass1.png`
  (native JPEG bytes despite initial extension), `desktop-pass2.jpg`,
  `desktop-final.jpg`. Screenshots are unretouched; no synthetic plot replacement.
- Composition follows the source: compact title and filters, broad three-slot
  portrait shortlist, two equal-width scatterplots, then the inspected-manager
  quarterly research CTA. Existing rail typography/icons are retained.

### Findings resolved

- [P1] Choice-chip callback returned the function instead of invoking it. Fixed;
  period, filters and quarter shortcuts now execute, with regression tests.
- [P2] Tall date control separated the subtitle from its heading. Moved the
  subtitle into the title group; date stacks below the title on narrow phones.
- [P2] Chart ticks used awkward intervals and too much empty X range. Added nice
  numeric domains, shared across charts and stable through filtering; include
  negatives/outliers and SPY without clipping or manipulating actual values.
- [P2] Portraits/plot type and bottom action did not match reference hierarchy.
  Restored 92px portraits, increased chart type, aligned desktop filter row,
  and kept the primary quarter CTA on one line at the reference width.
- [P2] Selected labels used fixed-width leader anchors and could cross nearby
  markers. Measure the actual label dimensions and avoid labels/other dots.
- [P2] English phone X-axis copy crossed the chart boundary. Reserve three lines
  below ticks; native tooltip uses a readable dark surface. Mobile headings no
  longer compete with the date control for half the available width.
- [P1] Comparison loading/error could block original holdings. The shortlist
  and quarter path remain accessible; unavailable returns stay absent, not zero.

### Interaction and data verification

- Search and picker filter real managers; add/remove and the three-manager limit
  verified in-browser. Clicking a fourth chart point shows an explicit limit
  message without replacing the shortlist. No follow/save POST is implicit.
- Both chart selections update inspected manager and quarter CTA. Browser path:
  Li Lu Sharpe point → 2026 Q1 → quarterly holdings (report 2026-03-31, filed
  2026-05-15) → Research GOOGL. The exact manager/filing provenance is preserved.
- Common → 1Y recomputes 2025-09-02 to 2026-08-31; lower-turnover filter shows
  8/28 without changing dates. More filters and methodology dialog verified.
- All 28 managers' common-period annual turnover/CAGR/Sharpe independently
  match the existing `output/guru-turnover-20260910/analysis.json` to <1e-10.
  Actual common range is 2022-05-17 to 2026-08-31, 1075 observations, 4.29 years;
  22 cash-preserving simulations and 6 explicitly distinguished subset proxies.
- Stored 5-year simulation histories are rebased to the same actual sessions;
  SPY uses precisely those sessions. Source cutoff, method, coverage, disclosure
  timing and attribution reconciliations are validated; no price forward-fill.
- The source drawing puts Bill's CAGR point near 83% turnover while its card
  says 47.66%. Implementation correctly uses **47.66% in both charts and card**.
  The reference's illustrative point location is not copied over actual data.

### Verification evidence and bounds

- `desktop-1280.jpg`: 1280x720, normal vertical scrolling. `mobile-en-top-final.jpg`,
  `mobile-zh-top-final.jpg`, `mobile-en-chart-final.jpg`: 390x844, normal text scale.
  Mobile layouts stack shortlist/charts; controls, portraits and axes inspected.
- 453 full Flutter tests passed; 13 focused study tests additionally verify
  three-manager selection, null/error states, late-period response rejection,
  exact quarter routing, EN/ZH and 150% text at 390px.
- 63 focused Node tests passed, including shared turnover math, read-only cutoff
  recomputation, source reconciliation, authentication, 422 validation and
  `private, no-store` API behavior. Flutter analyze/i18n audit/release build passed.
- Browser error-log inspection returned no errors during the tested flows.
- Local preview only: `http://127.0.0.1:5186/?view=discover&discoverTab=managers&asOf=2026-09-10&lang=en`.
  This page compares retrospective 13F simulations, **not fund returns**; costs
  excluded and Sharpe Rf=0%. Current-manager cohort/survivorship and proxy limits
  are explained in the page. Correlation/causality claims are not added.
- [P3] Established Flutter font/icon rendering, ISO dates and canonical portraits
  differ slightly from the mock; preserved for consistency and provenance.
  No certification of production auth/deployment or unrelated Strategy Lab fixes.

Final reference/implementation comparison repeated after label collision fixes;
all scoped P1/P2 findings resolved. Responsive checks and native browser logs
remain clean. The temporary viewport override is reset for handoff.

Option 3 local final result: **passed**.

## Current acceptance: Fundamentals business-change workbench — 2026-09-10

- Purpose: inspect whether reported growth is supported by profits and cash,
  then evaluate the price. The old alphabetical ≥15%-growth list is removed.
- Four independently defined, overlapping screens; compact exact-value table,
  signed percentage-point changes, selected-company questions, dated model/price,
  and eight-quarter horizontal comparison. No composite investment score.
- Operating coverage now includes multi-method growth/revenue-stage companies;
  NVDA, PLTR and TSLA are no longer excluded merely by valuation formula. No
  bank/customer-cash/treasury-route FCF comparison is implied.
- Graphite components and real stock logos retained. Phone question tiles are
  two columns; selection opens a readable evidence pane and scrolls to its start.
  Search, screen selection, sort, price filter, pagination and return preserve
  state. History expands to desktop width and scrolls on narrow screens.
- `docs/fundamentals-2026-09-10.md` records metric definitions, counts, provenance
  and verification. 386 Flutter, 129 focused Node, 41 performance and 25 Ontology
  tests passed; analyzer, i18n and builds passed. No deployment or source mutation.

## Current acceptance: Discover Value Flow — 2026-09-10

- Replaced the empty external-jump placeholder with a native three-step research flow: stage selection → company comparison → evidence/valuation. Reused Graphite styling and canonical stock/Guru assets; no generated visuals or financial numbers.
- Eight stage cards display median company quarterly revenue growth and positive-growth breadth with a defined known-data denominator. Company table distinguishes revenue growth from published-value/price gap; selected company shows dated price/value, quarterly/TTM metrics, role and disclosure holders. No undated supplier/customer edges or quantified money flow is implied.
- Source inspection found the default Ontology SQLite empty. The independent existing taxonomy is now bundled (74 companies / 8 layers), with economic fields read from the already connected paid PIT model inputs and stored prices. No backend dependency on a developer's other directory at runtime.
- June cutoff: 54/74 financial models, 53 comparable valuations. August cutoff: 54/74 financial models, 54 comparable valuations. The 20 absent models remain explicitly visible, not fabricated or represented as zero. Classification version is retrospective/current; economic observations remain cutoff-filtered.
- Desktop: explicit stage selection, all-company search, reset, below-model-value filter, signed sort, exact company/section navigation, preservation of selection on return. PLTR drilldown retained 2026-08-28 and `origin=value_flow`. Guru avatar chips remain precise manager-entry actions.
- Mobile: horizontal stage rail starts at the selected stage, arrow controls, readable two-row Discover tabs, stacked comparison/evidence, auto-scroll after row selection, back-to-comparison control. Existing white MRVL logo receives contrasting dark background. EN/ZH plus 150% text tests passed.
- Validation: Flutter 378 passed; focused Node regressions 118 passed (including 9 new value-chain tests and the saved-origin integration test); performance 41 passed; Ontology 22 Node + 3 Python passed; analyzer, i18n audit and web release build passed. API: unauthenticated 401, invalid calendar date 422, both June/August observations cutoff-safe.
- Screenshots and browser checks: `output/value-flow-20260910/`. Local preview only, no GitHub push, AWS deployment or production-auth certification.

No performance improvement claim is made from these local checks. Model coverage expansion is separate from this UX task.

## Current acceptance: Guru × valuation × CTA Strategy Lab — 2026-09-10

Local functional/visual gates passed. Production release not performed.

- Replaced the passive Top-3 selection preview with a three-step builder:
  avatar-based Guru selection, Top 1–10, adjustable premium filter with 15/30%
  presets, and actual KMLM/DBMF ETF allocation with 30/50% presets. Shared
  Graphite palette/typeface retained; no generated portraits or fake curves.
- Compared four daily curves over identical dates, with range selection,
  drawdown, full-width metric table and stock/CTA/cash allocation. Every
  exclusion and filing/model date is inspectable in Rebalance audit. Editing
  rules labels old results until explicit recalculation; saving is explicit.
- Browser iteration fixed a zero-width CustomPaint plot, a narrow desktop
  metrics table, cramped mobile date labels and an ambiguous result recipe.
  Result now auto-scrolls into view and names the actual managers, Top N,
  premium limit, CTA target and transaction-cost basis.
- Input reference: `codex-clipboard-b0414546-845c-4b7f-830c-ff213841c764.png`.
  Final screenshots in `output/strategy-lab-20260909/`: 04 builder, 05 actual
  Buffett/KMLM curve, 06 drawdown, 07 audit, 08–11 mobile EN/ZH. All opened and
  visually checked at 1600×1100 or 390×844; no image retouching. Earlier 01–03
  captures are superseded by original SEC filing recovery.
- 370 Flutter / 119 backend / 41 performance regression tests pass, analyzer
  and bilingual audit pass. Real browser shows no error logs. Mobile large
  text 1.5× is fixture-tested in both languages; responsive phone browser
  checks used default text scale.
- Source boundaries: 18 missing original filings recovered into a separate
  artifact, no paid DB writes. Stan Moss's unreconciled 2023-Q4 original and
  pre-inception CTA windows fail explicitly. Partial valuation coverage means
  cash, not zero-valued stocks or silently redistributed missing weight.
- See `docs/strategy-lab-2026-09-09.md` for calculations, nine real-data checks,
  historical-original policy, source limits and runtime artifact wiring.

## Current acceptance: Portfolio integration — 2026-09-09

Implementation/test gates passed; **real-account acceptance blocked**.

The primary book now reads the original per-user portfolio source instead of
presenting decision-ledger allocations as broker positions. Overview, valuation
contributions, concentration, stress scenarios and Guru weight comparisons are
implemented. The ledger remains separate. No source records were mutated.

Source screenshot: `codex-clipboard-11b34636-f942-4a03-99bc-fc6125fe7cd5.png`.
The real local runtime still uses a development identity with no production
portfolio. Screenshots in `output/portfolio-research-20260909/` therefore verify
the honest source/account state, not the populated broker account. Never label
them as evidence that the user's actual holdings have been loaded.

Fixture tests verify all three analysis tabs at 390px in English/Chinese and
1.5× text; they exposed and fixed a stress-row overflow and missing Material
ink ancestor. Aggregate arithmetic, currencies, missing values, raw-unit
preservation, partial Guru coverage and account isolation have dedicated tests.
See `docs/portfolio-research-2026-09-09.md` for formulas and remaining acceptance.

## Current acceptance: Horizontal quarterly research book — 2026-09-09

final result: passed
## 2026-09-11 Portfolio history repair

Home retains the existing native Flutter design and canonical logos. Actual
broker history now drives NAV and two separately labelled P&L views. The P&L
axis includes zero; the filled chart uses a quiet solid tint. Date controls
rebase P&L without changing the full-report summary/ranking, which retains its
own date labels. Pointer, touch and keyboard slider inspection are available.
Full details and data boundaries: `docs/portfolio-history-repair-2026-09-11.md`.

## 2026-09-11 — Guru directory below the comparison charts

- Retained the accepted two-chart/shortlist design, source portraits and
  financial metrics; added a complete, sortable 29-manager directory beneath.
- Inspection now works independently of the three-person comparison cap.
  A chart point reveals and outlines the matching portrait row; the row expands
  quarters and the exact-filing holdings action. Return links show both charts.
- Desktop browser checks at 1487×1058: real portrait loading, readable numeric
  columns, mint selected row/ring and labels, exact-quarter navigation and
  three-comparison/fourth-inspection behavior. Search Li Lu reconciles to one
  point in each chart and one directory row; reset restores 28 plotted / 29 listed.
- Mobile checks at 390×844, EN/ZH: rows and metrics stack without horizontal
  overflow; quarter chips wrap; holdings and return-to-charts remain reachable
  through ordinary vertical scrolling. Larger text is covered by widget tests.
- Missing simulation: Nick Sleep / Qais Zakaria remains listed with em dashes
  and no invented dot. Search-only-unavailable has a distinct chart-empty state.
- Validation: 16 focused and 459 total Flutter tests; analyze; bilingual audit;
  ontology source/built checks and test suite; 4 Guru study backend tests;
  production build and local preview build all pass. No source data edits.

## 2026-09-11 Strategy full investment / historical holdings

- Existing strategy workflow retained; default allocation now explicitly says
  eligible-stock full investment. CTA weight and financing remain separate.
- Historical holdings has previous/next controls, all rebalance dates, stock /
  CTA / cash summaries, sized weight bars, stock logos, Guru portraits and names.
- Verified native browser navigation from 2026-08-17 back to 2021-08-30 and
  forward to 2021-11-16. The actual stock list and weights change; first/last
  arrows disable appropriately. This is not a decorative date selector.
- At 1440×1000 desktop and 390×844 mobile, the snapshot header, date control,
  allocation metrics and stock evidence wrap without horizontal clipping.
  EN/ZH mobile widget checks additionally cover 150% text size.
- Screen clearly identifies post-rebalance simulation targets, not brokerage
  holdings. Missing manager evidence and valuation exclusions remain inspectable.
- First snapshot: MU 35%, AAPL 35%, KMLM 30%, cash 0%; actual manager portraits
  remain attached to the stock rows. Data comes from the strategy ledger.
- Local artifacts: `/Users/yudonglu/Documents/strategy-full-investment-acceptance-20260911/`.
  No production visual/release certification is implied.

Local preview only. The user asked to restore the old Guru-style horizontal
quarter interaction and make the earnings research flow easier to understand.

### Source and paired evidence

- Source annotation: `/var/folders/3k/0wsqd58n6w71n8tyql0t09fc0000gn/T/codex-clipboard-6f0091a2-16a5-43b9-a935-d4a8104417a1.png`.
  The existing `QuarterTimelineSelector` and `ValuationQuarterResearchPanel`
  supplied the legacy product pattern: directly selectable horizontal quarters,
  followed by selected-quarter analysis. No new mock theme or assets were made.
- Actual before and after were opened together in the same comparison input:
  `output/earnings-quarterbook-20260909/before.jpg` and `desktop-final.jpg`.
  Both are 1487×1058 at 1:1 density, English, TSLA, cutoff 2026-08-28, Financials
  & sources, selected 2026 Q2, results view, page top. No retouching/rescaling.
- The supplied image is a cropped reference; precise geometry was compared with
  the matched-viewport before capture, not the differently cropped attachment.
- Additional readable region evidence: `tsla-q1-qa-desktop.jpg` shows an expanded
  historical management answer; `mobile-en.jpg` and `mobile-zh.jpg` show the
  quarter strip and selected-quarter controls at 390×844. These were opened and
  visually inspected, not judged from paths alone.

### Findings and iteration

1. P1, original: available quarters were hidden inside one dropdown, while
   duplicate headings occupied the research area. Replaced with direct-select
   horizontal cards, visible financial previews, a persistent scrollbar, year
   jump, newer/older strip navigation and a return-to-latest action.
2. P1, original: users had no clear reading sequence. Added three short stages:
   choose a quarter; read results/guidance/Q&A; open the valuation worksheet.
   Current/prior/change columns and a compact model/diligence column replace the
   scattered metric boxes and oversized single-column summary.
3. P2, first visual pass (`desktop-pass1.jpg`): selected tab icon inherited a dark
   foreground. Explicit semantic colors now keep icons legible in both states.
   Quarter dates now explicitly say Published rather than leaving the date type
   ambiguous. Final paired capture verifies both changes.
4. P2, resilience test: the year/navigation toolbar overflowed by 15px in English
   at 390px and 1.5× text. Replaced its rigid row with a wrapping control group.
   Both-language 1.5× tests now pass; final English/Chinese mobile captures show
   reachable controls and intentional horizontal card clipping, not page overflow.

### Required visual surfaces

- Fonts: existing product typeface retained; 23px panel heading, 16px quarter
  labels, 12px card values, 13px comparison rows and 30px model value. Metadata
  is secondary; long source excerpts wrap. No replacement font download.
- Spacing/layout: one compact heading; 160px quarter cards with 8px gutters;
  responsive horizontal strip. Results/model columns split at 820px and stack
  on phones. The parent company header, rail and research tabs are untouched.
- Colors: existing Graphite/mint palette, amber negative-change emphasis;
  capex direction is neutral, not automatically treated as good/bad. Selected
  quarter has a mint border/check and remains identifiable without color alone.
- Assets: canonical TSLA/company artwork in the parent header retained. The
  quarter controls use the shipped Material icons. No generated logos, portraits,
  synthetic charts or decorative code approximations.
- Copy: explicit date types and quarter labels; three distinct content tabs;
  missing Q&A/guidance stays visible and honest. English/Chinese UI and the
  separation between historical evidence and the current private DCF are clear.

### Verification and boundaries

- Full Flutter suite: 343 passed, including 14 focused earnings tests. Tests
  cover 1487×1058, 1280×720, 390×844, EN/ZH, 1.5× phone text, year jump/latest,
  direct selection, race/error/identity states, exact node/cutoff matching and
  valuation navigation without writes. Analyzer, i18n audit and build pass.
- Browser: TSLA Q2 → Q1 updates values and reveals four stored Q&A; an answer
  expands with its original date/source. Year jump 2025 selects 2025 Q4 and
  changes guidance/Q&A counts. Open valuation retains TSLA and the workspace
  cutoff; no hypothesis edits or saves. Phone older-quarter navigation and
  Chinese guidance/Q&A controls work. Final browser error log is empty.
- Timeline previews reuse already loaded company history matched to the exact
  fiscal period and publication node returned by the quarter API. No new API
  endpoint, bulk transcript request, database write or financial recalculation.
- The available-quarter list is stored research coverage, not a claim that all
  calls have complete transcripts. Q2 missing Q&A is not filled from Q1.
- No P0/P1/P2 findings remain in this local scope. P3: long original questions
  retain the existing expandable excerpt presentation rather than invented
  topical summaries. Production deployment and authentication are not certified.

---

## Previous acceptance: Four Discover research lenses — 2026-09-09

final result: passed

Scope: local Discover interaction and visual refinement, not a production
deployment or certification of the underlying investment models.

### Visual comparison and iteration

- Source: the user's `codex-clipboard-e54551b0-8e08-4c99-9a79-629123dc5a3b.png`
  and the existing runnable Discover screen. The request intentionally replaces
  the generic selected-company panel with four distinct research experiences.
- Opened `output/discover-lenses-20260909/before.jpg` and
  `debate-desktop-final.jpg` together in one comparison input: 1487×1058,
  English, GOOGL, 2026/Q2, cutoff 2026-08-28, top of page. Both are unretouched
  browser captures at the same density. A capture during scroll animation was
  discarded and replaced after the viewport settled.
- First pass P2: the disagreement panel stacked both manager groups despite
  having enough desktop width. Groups now compare side-by-side above 460px
  inner width, stacking on phones.
- Second pass P2: names, percentage changes and ending weights competed on one
  line. Names/portraits/actions now have a dedicated row; share changes and
  weights wrap separately. The shorter question also fits the narrow column.
- Final paired comparison preserves the rail, four entry cards, company list,
  selection and Graphite hierarchy. The deliberate 22px card-height increase
  accommodates specific actions. The selected lens now visibly changes both
  table columns and the evidence panel; the real price/value chart remains below.

### Five visual surfaces

- Typography: existing product fonts and hierarchy retained; distinct research
  question, manager identity and numeric changes do not overlap. Muted labels
  remain secondary to evidence. No new font assets.
- Layout: existing split view retained; manager details have intrinsic height,
  expansion controls, and mobile stacking. Mobile growth tables keep all four
  columns readable at 390px, with no page-level horizontal overflow.
- Color: existing Graphite, mint, blue growth and amber disagreement accents;
  no new design system. Active card, panel and metric emphasis share a lens color.
- Assets: canonical company logos and existing Guru portraits reused directly.
  No generated portraits, replacement marks, synthetic plots or retouched data.
- Copy: four different diligence questions and specific next steps. Dates,
  denominator definitions, unverified corporate actions, missing observations
  and non-causal model comparisons remain explicit in English and Chinese.

### Browser and regression evidence

- All four cards tested on the same GOOGL selection; each changes the evidence,
  list metrics and downstream action, not just the heading. Active-card reclick
  preserves its lens; Reset filters explicitly returns to the full screen.
- Growth → quarterly earnings/Q&A; revision → private valuation worksheet;
  returning preserves company, cutoff and lens. Buffett portrait/name opens
  his exact GOOGL filing/quarter trajectory. No scenario edits or saves in QA.
- Checked English and Chinese mobile disagreement/expanded rosters, plus the
  English mobile growth table. Captures: `debate-mobile-en.jpg`,
  `debate-mobile-zh.jpg`, `growth-mobile-en.jpg` in the same evidence directory.
- Twenty-eight focused tests cover the four lenses in both languages at
  1487×1058, 1280×720 and 390×844, grouping, missing data, navigation, expansion
  and no-write browsing. Full Flutter suite: 337 passed. Backend investment
  suite: 65 passed. Existing performance suite: 41 passed. Analyzer, bilingual
  audit, release build and whitespace checks pass. Browser error log: empty.

### Boundaries

- This is a dated, bounded source extract, not exhaustive live market coverage.
- Reported 13F share differences are not verified transactions or motives.
- Model revisions require matching currency, formula and model version. Financial
  before/after inputs are not a causal valuation bridge; endpoints are never
  reconstructed from rounded percentages.
- Original curves, models, private scenarios, financial data and production
  services were not changed. Only the local read API and local preview restarted.
- No outstanding P0/P1/P2 findings for this delivered scope. Production auth,
  full WCAG certification and deployment remain outside this acceptance.

---

## Previous acceptance: Research company search — 2026-09-09

final result: passed

Local preview only. Product Design scoped implementation of the user's company
switcher screenshot; the selected Graphite visual system is preserved.

### Paired evidence and five surfaces

- Opened `output/personal-valuation-20260909/company-switch-before.jpg` and
  `company-switch-after.jpg` together in the same comparison input. Both are
  1487×1058, English, TSLA Overview, 2026-08-28, company switcher open. The larger
  searchable directory intentionally replaces the tiny ticker-only alert.
- Typography: existing product font, clear 23px heading and 16px ticker; company
  name/date are secondary, not a repeated paragraph or a dense block of raw data.
- Layout: 660px maximum width, anchored top, intrinsic content height capped at
  680px. Search remains in position as result count changes. Scrollable rows,
  responsive stacked dates and preserved existing Research behind the overlay.
- Colors: Graphite panel/border and mint input/selection; no new color system.
- Assets: existing company marks. White ABBV, AMZN and UBER assets use dark
  backdrops. No invented images or approximated logos.
- Copy: name-or-ticker search, current/recent state, model date and research cutoff
  are explicit. EN/ZH UI is complete; legal issuer names remain source-original.

### Findings resolved

1. P1: the old flow required memorized ticker codes. The new read-only index
   supports issuer-name search and one-click exact-ticker navigation, with real
   logos and dated model availability. No guessed substitute is sent.
2. P2: the first implementation retained a tall empty panel for one result.
   Changed to intrinsic-height layout; empty/error/loading panels also fit their
   content. A fixed-header estimate failed default-font tests and was replaced
   with actual flexible layout before acceptance.
3. P2: mobile large type clipped row content. Row extents now scale with text;
   tested 390px width, 1.5× text and 284px keyboard inset with no overflow.
4. P2: the first local translation helper passed arguments in reverse order.
   Corrected to the existing `context.tr(zh, en)` convention and verified both
   languages in widget tests and the actual browser.
5. P2: white ABBV artwork was invisible on the shared default white background.
   Preserved the exact asset and corrected its picker background contrast.

### Verification

- 12 new picker tests + 17 Research tests: 29 passed. Includes lookup/ranking,
  no per-keystroke request, desktop/phone EN/ZH, Enter/arrows/Escape, clear/empty,
  timeout/retry/late completion, cutoff/future-data rejection, scrolling and
  existing unsaved-draft guard. Current-company selection never reloads a draft.
- Full Flutter suite: 309 passed; investment backend suite: 64 passed, including
  5 new catalog tests; performance suite: 41 passed. Analyze/i18n/build pass.
- Real browser: TSLA → search `nvidia` → NVDA, unchanged cutoff, then TSLA
  appears under Recent when reopening. Current selection, name and model date
  are visible; there are no synthesized prices or valuation changes.
- Phone evidence at 390×844: `company-switch-mobile-en.jpg`,
  `company-switch-mobile-result.jpg`, `company-switch-mobile-zh.jpg` in the same
  output directory. Single-result panel inspected at native size, no blank void.
- Read-only source metadata and existing issuer catalogs only. Catalog rows are
  not a full model-lineage audit; the pre-existing full-research validation still
  runs on open. No source data, saved hypotheses, GitHub or AWS writes.

## Previous acceptance: Research disclosed holders — 2026-09-09

**Result: passed (local preview only).** Scoped redesign of the user's
"Other disclosed holders" screenshot; the selected Graphite option 2 remains
the visual system. No new product shell, synthetic financial data or generated
portraits were introduced.

### Paired visual evidence

- Before: `output/personal-valuation-20260909/holders-before-desktop.jpg`.
  Final comparison: `holders-final-1280.jpg` in the same directory. Opened
  together in a single comparison input at native 1280×720, 1×, NVDA,
  English, cutoff 2026-08-28, Financials & sources, Baillie Gifford selected.
  The raw-number accordion is deliberately replaced by a portrait roster and
  selected disclosure panel. All eight source rows are retained and ordered
  by reported shares, not by name or an invented investment ranking.
- Wide-screen delivery: `holders-final-desktop.jpg`, 1720×1120.
- Phone evidence: `holders-mobile-list-en.jpg`, `holders-mobile-detail-en.jpg`
  and `holders-mobile-detail-zh.jpg`, 390×844. Inspected at native size:
  portrait list, in-place details, readable exact counts and sources/actions.

### Findings and fixes

1. **P1, fixed:** the old section did not bind the existing avatar component.
   Both Research overview and detailed evidence now use the canonical
   `GuruAvatar`; all eight NVDA avatar URLs return image/png, HTTP 200,
   144×144. Institution/manager imagery remains the project's assigned asset.
2. **P2, fixed:** raw shares were unformatted and centered beside a naked URL.
   The roster exposes comparable compact shares and reported-book weights;
   the detail pane separates exact/current/prior/raw change, reporting/public
   dates and a labeled SEC source button.
3. **P2, fixed:** the initial split breakpoint left normal 1280px laptops in
   stacked mode. Reduced available-content breakpoint from 1040px to 940px;
   1280px now uses the split layout, phone/tablet and larger type stack safely.
4. **P2, fixed:** a debug-mode Material ancestry warning affected the decision
   checkbox. Added its explicit transparent Material parent. Tests and the
   final browser console are clean.
5. **P2, fixed:** phone widget tests initially tapped a research tab outside
   the horizontally scrollable strip. The fixture now scrolls the actual tab
   into view before exercising the flow; no production workaround was added.

### Five fidelity surfaces

- Typography: existing font/tokens; 22px section heading, 24px exact share
  figure, restrained 11–15px facts and secondary labels. Long names wrap;
  aligned columns retain missing values as em dashes.
- Spacing/layout: existing 216px desktop rail, 8px section corners, thin
  separators, 60/40 roster/detail split. Compact layouts expand a selected
  row inline; no horizontal page overflow in tested widths.
- Colors: existing graphite panels and mint selection/actions. Unverified
  raw changes are not green/red buy/sell signals; amber caveat stays adjacent.
- Images/icons: real pre-existing 42/52px portraits, unchanged brand logo and
  Material icons. No substitutes, placeholder art or external avatar service.
- Copy: share and weight denominators, original-entry attribution, delayed
  filings, missing prior coverage and decision-save timing are explicit in
  English and Chinese. Clicking a holder is not a persisted decision.

### Interaction and regression evidence

- 14 dedicated tests: formatting/missing/zero, non-mutating sort, English and
  Chinese at 1720/1280/1024/390px, selection/attribution, no automatic writes,
  search/no results/clear, phone expansion/collapse, empty coverage and exact
  Guru navigation. Full Flutter suite: **289 passed**.
- `flutter analyze`, `npm run audit:i18n` and release web build passed.
- Browser: eight portraits rendered; manager search filtered accurately;
  selected Renaissance → Explore Guru history retained NVDA, cutoff and its
  exact filing (`0001037389-26-000059`); phone and language switch verified;
  captured error console empty.
- Backend data, saved user hypotheses, DCF formulas and production deployments
  are unchanged. The preview build uses local development authentication and
  is not a production artifact.

## Previous acceptance: Personal valuation worksheet — 2026-09-09

Scope: the user's requested editable annual hypothesis table and per-account
backend versions in the existing local preview. This deliberately replaces the
old years-as-rows form; it is not a new visual direction or a production release.

### Visual truth and paired evidence

- Selected visual system remains Graphite option 2:
  `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-82f085f7-6688-4bf4-84f2-fb3909ae6757.png`.
- Exact before state: `output/research-redesign-20260909/editable-valuation.jpg`.
  After: `output/personal-valuation-20260909/final-googl-desktop.jpg`. Both opened
  together in one comparison input: GOOGL, English, 2026-08-28, Valuation, Base,
  1487×1058 CSS/pixels, 1× density. The standalone value remains $174.11.
- The user's original financial comparison was also compared in one input:
  `output/research-redesign-20260909/financials-desktop.jpg` and
  `output/personal-valuation-20260909/final-financials-desktop.jpg`, same NVDA,
  English/cutoff/viewport. Actual numbers and original evidence are preserved;
  the full-width grid, delta column and model-editor link are intentional changes.
- Final main deliverable: `output/personal-valuation-20260909/final-nvda-desktop.jpg`.
  Real stored Base inputs, not the test-only saved hypothesis.
- Phone comparison: `first-phone.jpg` and `final-phone-en.jpg` opened together
  at 390×844 CSS/pixels, 1×. Earlier capture used an isolated saved QA version;
  final capture uses the normal unsaved Base. The value differences are expected,
  not a visual regression. `final-phone-grid-en.jpg`, `final-phone-year5.jpg`
  and `final-phone-grid-zh.jpg` verify fixed row labels, access to all five years,
  nearby Save and bilingual input labels.
- Focus review inspected the forecast and financial table regions in these
  paired native-resolution images; each cell was readable at 1×. Additional
  phone close views expose the focused input, borders, row alignment and save
  action without manufacturing a raster crop or substituting generated data.

### Comparison history and resolved findings

1. **P1, fixed:** NVDA had an explicit DCF but the personal adapter excluded its
   multi-method route. Enabled the reviewed operating-company route family while
   retaining financial/customer-cash/NCI/currency guards; exposed post-DCF
   reconciliation instead of relabeling the published blend as personal DCF.
2. **P1, fixed:** Annual revenue was not editable and the table lacked a clear
   personal hypothesis/save/reload workflow. Added linked editable annual cells,
   private notes and immutable backend versions with restoration.
3. **P2, fixed:** `first-desktop.jpg` duplicated a large valuation result in the
   sidebar and pushed Save below the desktop fold. `second-desktop.jpg` and
   final desktop replace the duplicate result with the scenario name; Save is
   visible beside the table.
4. **P2, fixed:** Initial header/caption heights overflowed in fallback-font
   layout tests. Explicit line heights, bounded caption wrapping and scaled row
   sizes pass all bilingual/responsive and large-text tests. Final browser cell
   text, dates and controls fit without clipping.
5. **P2, fixed:** `first-phone.jpg` had different summary label heights, putting
   the platform value below the other second-row number. Fixed label slots align
   both amounts in `final-phone-en.jpg`.
6. **P2, fixed:** Stacked phone layout placed the save action too far from the
   cells. A functional Save action now sits in the mobile table header; actual
   browser click opened the confirmation dialog, with saving disabled until
   ownership is confirmed. Cancel performed no write to the normal user store.

### Required fidelity surfaces

- **Typography:** original Graphite font family/weights retained. 18–20px panel
  titles, 27px summary amounts, 13px editable cells, 11–12px supplementary labels.
  Numeric inputs align right; actuals are muted and computed cash flows use the
  normal foreground. Desktop fallback, phone wrapping and 1.5× text were tested.
- **Spacing/layout:** 24px workspace padding, 8px panel corners, 22px linked-column
  gap and 310px desktop scenario rail. Five forecast years are parallel columns,
  with an adjacent actual column. On phones only the data columns scroll; the
  row-name column and app navigation remain visible. Additional vertical scroll
  for notes, guidance and diagnostics is intentional progressive disclosure.
- **Colors/tokens:** existing graphite/blue-grey surfaces and borders, mint
  editable cells/actions, amber unsaved state, numeric red negative comparison.
  Locked facts, editable assumptions and calculated output are visibly distinct.
- **Assets:** existing ThesisForge and exact company logos retained; Material
  table/save/edit/lock/history icons. No generated financial chart, custom logo
  approximation, placeholder image or decorative asset added.
- **Copy/content:** clearly distinguishes TTM CFO−capex from parent FCFE, fiscal
  reports from rolling annual forecast periods, mechanical templates from
  management guidance, current share count from forecast values, and private
  DCF from the published blend. Missing inputs do not become zeros. Saving is
  explicit and versioned, with no broker order or guaranteed-return language.

### Functional verification and limits

- 269 full Flutter tests; 52 backend/workflow tests; 41 performance regression
  tests passed. Static analysis, bilingual audit, release build and whitespace
  checks passed. No performance uplift is claimed.
- Real browser: edit NVDA year-two revenue, edit notes/name, required ownership
  confirmation, save v1, reload/restore, change margin, append v2, verify v1 is
  unchanged. Only `output/personal-valuation-20260909/browser-qa.sqlite` received
  QA records; the normal research store is restored for the user's preview.
- Phone: focus year one then year five, row labels stay fixed; nearby Save opens
  the dialog; cancellation writes nothing; English/Chinese both inspected.
  Financials → Build your hypothesis returns to the same NVDA/date Valuation.
- Browser console errors: none. Backend ownership spoofing, cross-owner version
  use, reopen durability, immutable history, invalid fields and stale results
  are separately tested. This is not accessibility certification, refreshed
  investment underwriting, production migration approval or live AWS testing.

**Follow-up polish:** P3 — the phone requires horizontal scrolling for all years,
with a visible scrollbar and fixed labels; this preserves usable numeric cells.
Framework-generated assistive text (such as the character counter announcement)
uses the host Flutter locale; visible application copy and numbers are bilingual.

**Implementation checklist:** layout, linked inputs, exact arithmetic, ownership,
version restoration, failure states, mobile Save, paired captures and local
preview verification completed. Production deployment remains a separate request.

final result: passed

## Previous acceptance: Research refinement — 2026-09-09

Scope: the existing local Research company workspace. No deployment, production-data changes or new valuation assumptions. This is an intentional extension of the approved Graphite option 2, not a pixel clone of its Home/manager three-track layout.

### Reference and rendered evidence

- Visual-system reference: `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-82f085f7-6688-4bf4-84f2-fb3909ae6757.png`, 1487×1058.
- Same-company baseline: `output/research-redesign-20260909/before-desktop.jpg`, NVDA, English, 2026-08-28, Overview, 1487×1058.
- Final: `output/research-redesign-20260909/final-desktop.jpg`, same company, language, cutoff and Overview. New default range is 5Y instead of the baseline's unfiltered history; All preserves the full available history. This intentional state difference is not a financial-value comparison.
- Desktop source/final and selected Graphite/final were each opened together in a single comparison input. All desktop images use 1487×1058 CSS/image pixels, 1× density; no device frame or image scaling.
- Phone first/final were opened together: `first-phone.jpg` / `final-phone-en.jpg`, 390×844 CSS/image pixels at 1×. `final-phone-zh.jpg` verifies the matching Chinese state.
- Focused content checks: `evidence-desktop.jpg` verifies readable management excerpts, source actions, actual manager portraits, countercase and standalone DCF distinction; `holders-anchor.jpg` verifies direct navigation to holder details; `editable-valuation.jpg` verifies the preserved GOOGL scenario editor.

### Findings, fixes and iteration history

1. [P1, fixed] Research with only a retained candidate parameter displayed a search-only empty screen. Exact candidate fallback now loads NVDA; explicit valuation selection takes precedence. Browser verified the user's original route.
2. [P1, fixed] NVDA's read-only snapshot offered “Set my assumptions,” leading to an unsupported workflow. Read-only model and decision states now explain the boundary and expose valid inspection/watch actions. Supported GOOGL FCFE editing remains intact.
3. [P2, fixed] The original overview hid almost all evidence behind one expansion and had no range/report controls. Final overview exposes the curve, latest changes and next action, then readable metrics, guidance, holders, countercase and model scope. Separate Financials & sources preserves detailed tables, raw-source audit and manager attribution selection.
4. [P2, fixed] Initial desktop chart pushed the metric strip below the first screen (`first-desktop.jpg`). Chart height reduced from 290 to 240px; `final-desktop.jpg` now includes all four metric values at the same viewport.
5. [P2, fixed] The initial phone label order pushed Valuation outside the visible tab strip; Valuation is now second, other tabs remain horizontally reachable. Automated bilingual phone flows cover Overview → Valuation → Financials → Decisions.
6. [P2, fixed] Two-line phone metric labels misaligned the price/value/gap numerals (`first-phone.jpg`). Equal label slots align all three amounts and dates in `final-phone-en.jpg`.
7. [P2, fixed] The “All holders” link initially landed at the top of Financials, before guidance and metric sections. The final keyed scroll anchor places the full holder list in view (`holders-anchor.jpg`).

### Five required fidelity surfaces

- **Typography:** retained app font/Graphite family and existing weight hierarchy. Ticker 28px; section headings 18–20px; facts 22–29px; controls/content 11–14px. Long company names wrap naturally; phone amounts align; small audit captions remain supplementary rather than the only source of a critical fact.
- **Spacing/layout rhythm:** retained 216px desktop navigation, 28px workspace padding (18px compact), restrained 8px card corners, 20px internal padding, 22px linked-column gap. Desktop uses curve/evidence tracks; phone stacks them and retains horizontal chart ranges/tabs. Additional scrolling for audit details is intentional; no page-level horizontal overflow.
- **Colors/tokens:** existing graphite panels, thin blue-grey borders, mint selection/value/actions and amber caveats. Positive and negative market-model gaps are numeric comparisons, not buy/sell colors. No generated backgrounds or new visual language.
- **Image quality/assets:** existing ThesisForge logo, true ticker logo and existing manager portraits. Real-data native chart reused; no fabricated financial illustration or placeholder logo. Same original Material icon library as the existing product.
- **Copy/content:** facts, management statements, model calculations and personal decisions are explicitly separated. Missing values remain unavailable; no peer/KPI/ROIC claims. Recorded report dates, price dates, sample coverage, standalone/blended distinction and retrospective model-version caveats are visible. Language QA covers English/Chinese UI; verbatim evidence and formulas remain source-original.

### Verification and boundaries

- 254 Flutter tests passed (237 prior + 17 Research tests), including route identity, date filters, model-comparability guards, responsive/bilingual states, exact company switching, empty/wrong-company states, range/report controls, watch-only persistence and unsaved-scenario protection.
- 45 backend workflow/read-model tests and 41 performance regression tests passed. Static analysis, bilingual audit, diff whitespace check and release preview build passed.
- Real browser: original candidate route; 1Y preset changed curve to 4 model nodes/251 price samples; clicking a range endpoint changed the plotted sample set; selecting the preceding NVDA report showed $232.91 without changing the 2026-08-28 workspace cutoff. GOOGL scenario Year 2 growth change recalculated the standalone result from $174.11 to $178.15, flagged unsaved state, and required confirmation before switching away. Test draft was discarded. Watch writes were checked through isolated fixture tests, not real user investment records.
- Browser error logs: none. Desktop and phone screenshots inspected; 1024×768 and existing 1280×720 layouts covered by tests. No claim of assistive-technology certification, conversion uplift, full financial re-audit or production readiness is made.

**Follow-up polish:** P3 only — narrow phone screens require scrolling to the report inspector and lower evidence panels. This is intentional progressive disclosure; primary company/range/valuation actions remain reachable. Source encoding cleanup and licensed-data completeness are separate data tasks, not silently corrected here.

**Implementation checklist:** layout, exact route handling, source navigation, read-only/editable flows, regression tests, paired screenshots and local preview retention completed.

final result: passed

## Current acceptance: Discover redesign — 2026-09-09

Scope is the existing private local preview, not production. Product Design's existing-project/image-to-code workflow was grounded in the already selected Graphite option 2 and the original Discover capture. The user requested a richer, distinct discovery experience; the four collections are an intentional extension, not a pixel clone of Home.

### Visual truth, evidence and normalization

- Visual-system reference: `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-82f085f7-6688-4bf4-84f2-fb3909ae6757.png` (1487×1058).
- Actual old Discover: `output/discover-redesign-20260909/before-desktop.jpg`, 1487×1058; selected GOOGL, 2026-08-28.
- Implementation: `output/discover-redesign-20260909/ready-desktop.jpg`, 1487×1058; selected NVDA, same cutoff and English mode. The different selected stock is intentional; financial numbers are not compared as a visual regression. Compare Graphite type, chrome, logo treatment, border rhythm and working hierarchy instead.
- Phone: `mobile-first.jpg`, `final-mobile-list.jpg`, `final-mobile-detail.jpg` (initial inherited scroll), and the final verified phone evidence listed below; 390×844 CSS and image pixels, 1×. Desktop is also 1×. No artificial device frame, image rescaling or generated chart used.
- Before/current images were opened together in the same comparison input, not judged from file paths alone. Focused phone detail checks inspect typography, curve legend, assumptions action and manager evidence at full resolution.

### Iteration history

1. [P2, fixed] Initial Discover repeated Home's two rows of lenses with no reason to investigate. Separate collections, explicit rules, wider evidence table and dedicated manager/fundamentals entries now establish the workflow.
2. [P2, fixed] Initial desktop/phone headers consumed excess vertical space. Paired captures compare the first render against the compressed intro. Desktop places the date beside the heading; phone uses a short title, single-row section navigation, one real example per collection and a horizontal carousel.
3. [P2, fixed] Compact empty-collection copy overflowed by 4px in the English phone widget fixture. The compact collection slot is 164px; empty/populated bilingual tests pass without RenderFlex exceptions.
4. [P2, fixed and browser verified] Browser auto-scroll initially retained the list offset after opening a phone detail, dropping the user into the chart body. Detail now has a keyed scroll boundary and a post-frame evidence anchor. The same-input pair `final-mobile-detail.jpg` / `verified-phone-detail.jpg` confirms entry at Back to discovery, NVDA identity, disclosure context, dated price/value and the full curve. `verified-phone-zh.jpg` verifies translated detail in the same viewport.
5. [P2, fixed] Search lost its accessible name once populated; it now retains a form label. Collections and company rows expose button semantics and selected states. Query, sort, coverage and manager selection persist through URL state.

### Required fidelity surfaces

- Typography: existing Graphite/Flutter family and weights; 30px desktop heading, compact mobile heading, consistent 11–14px table/control text. Company names truncate deliberately in bounded rows; full name appears in research detail.
- Spacing: 12px collection gutters, 16px card padding, ruled table rows and split evidence tracks. Phone intentionally needs vertical scrolling to reach the full explorer; cards expose concrete examples first. No page-level horizontal overflow; only explicit carousels/tab strips scroll horizontally.
- Color: existing graphite surfaces, mint actions/positive gap, red negative gap, amber two-sided disclosure and a restrained blue growth marker. No decorative generated backgrounds.
- Assets: existing ThesisForge mark, actual company logos and manager-avatar assets; no custom logo substitutes, decorative SVGs or fabricated curves. Native published-data chart is reused.
- Copy and finance semantics: transparent collection rules, true cutoff, reported-quarter labels, missing coverage, reported-not-organic growth and estimate-not-return caveats. The economic-route scalar prevents the operating-company growth screen from guessing bank comparability. No investment recommendation is generated.
- Interactions: collection→filtered rows→exact stock→published evidence→personal valuation→back; manager/coverage/search/reset; broader growth thresholds; preserved manager catalog and Value Flow handoff. No user account or production ledger mutation was performed for these checks.

### Verification

Full Flutter suite: 237 passed. Backend workflow/read model: 45 passed. Performance regression: 41 passed. Static analysis, i18n audit and release preview build passed. Desktop browser GOOGL valuation round trip and filter preservation across reload were verified. Phone and Chinese UI were inspected; browser error logs were empty. Read-only published models remain explicitly separate from editable personal FCFE scenarios. Detailed ledger: `docs/discover-redesign-2026-09-09.md`.

final result: passed

Final `ready-desktop.jpg` was compared in the same input with the selected option-2 reference. No actionable P0/P1/P2 differences remain within the approved Discover extension. Residual P3: the phone explorer filters still require scrolling below the compact discovery carousel; this is intentional progressive disclosure, not hidden controls. Full assistive-technology certification and production-device telemetry remain outside this local check. The English Discover preview is retained as the deliverable. No AWS/Vercel/GitHub publication is authorized by this QA.

## Current acceptance: integrated Guru + Valuation research loop — 2026-09-08

**Local-preview QA: passed. Production release: not requested and not approved by this check.**

The user approved integrating collective Guru evidence, dated valuation research, observation saving and subsequent review while retaining the selected Graphite workbench. This extends the previous selected design; it does not replace the manager-specific workflow or the original terminal. Earlier sections below remain historical acceptance evidence.

### Comparison inputs and fixes

Directory: `output/integrated-guru-valuation-20260908/`. The confirmed option-2 image and previous implemented workbench are the visual references. Desktop comparisons use 1487×1058; phone comparisons use 390×844. Reference and implementation images were opened in the same comparison input. Real datasets differ between historical June and August views; layout and financial facts are evaluated separately.

- Desktop `01-desktop-first.jpg` and `03-desktop-final.jpg`: preserved existing logo/assets, Graphite fonts, ruled research tracks, mint selection and real chart painter. The approved consensus extension uses one candidate track with manager count, model gap and model change beside the company research track. The original manager-specific three-track desk remains under Managers.
- [P2, fixed] Manager mode initially duplicated the main hero/date controls and displaced existing filing actions. The redundant hero was removed. Retained manager tests use actual scrolling for below-fold actions, not hidden direct callbacks.
- [P2, fixed] `04-mobile-list.jpg` put only two candidate rows in the initial screen. Same-input comparison with `06-mobile-list-final.jpg` confirms the compact heading and horizontal lenses expose four full rows plus part of a fifth without reducing row legibility. No horizontal content overflow; only the lens rail intentionally scrolls.
- [P1, fixed] A failed company request was initially indistinguishable from missing coverage. Only the typed missing-PIT error now becomes the missing-model state; network and identity errors remain retryable and cannot retain another stock's chart.
- [P1, fixed] An unsupported personal FCFE route originally led to only a blocking text card. It now keeps the actual published curve, metrics, methodology and dated guidance visible in read-only form. The CTA says View valuation method, not Test my assumptions, for those routes.
- [P2, fixed] Stored guidance uses `excerpt`, not the old speculative `quote` field. Visible excerpts now include the observed date, speaker and HTTPS evidence link. Historical manager records from older report quarters no longer appear as current-quarter holdings.
- `02-watch-comparison.jpg` and live post-acknowledgment state: original/current columns remain readable, method mismatch is flagged rather than shown as a return, new filings clear after review and original values remain unchanged. This is a local retrospective observation, not a live investment outcome.
- `07-mobile-detail-final.jpg`: phone stock identity, dated context, model/price values and chart do not overlap; lower metrics, evidence and actions remain vertically scrollable. Selecting another stock retains exact identity. Return-to-candidates preserves the list cutoff.

### Required surfaces

- Typography and spacing: original app sans/CJK stack; 32px desktop headline, 28px phone title, existing financial-value styles, readable 11–14px metadata. Long issuer/legal names can wrap; tickers and model-gap numbers remain visible.
- Colors and imagery: existing Graphite palette, mint selections, neutral price series, published-model series, amber coverage caveats. Actual issuer logos and manager portraits, no generated financial artwork or replacement logo drawings.
- Responsive behavior: populated new flow tested at 1487×1058, 1024×768 and 390×844 in English and Chinese; retained workspace tests also cover 1280×720. Browser captures independently inspect desktop and phone. Intentional scrollable panels are not clipped overflow bugs.
- States and accessibility: labeled search, semantic choice controls, date menus, primary save/valuation actions, disabled duplicate save, loading, typed missing coverage, recoverable errors, exact-identity guards and back navigation. Existing Material focus behavior and chart semantic summaries retained. Broad assistive-technology certification is outside this local check.
- Workflow: shared holdings → ticker → historical data → save observation → review → acknowledge; existing manager selection/filing history, personal scenario route and read-only published-model route; no implicit portfolio position or trade.

Validation: 222 Flutter tests, 44 workflow/read-model backend tests, 41 performance regression tests; analyze, bilingual audit and diff whitespace checks passed. Release preview build passed. See `docs/integrated-guru-valuation-2026-09-08.md` for data coverage limits, commands and local-only architecture.

No unresolved P0/P1/P2 issue remains in this local integrated-flow scope. Full historical-book/model coverage, production migration/authentication and production-scale cold-start measurement remain separate release work, not silently accepted here.

## Current run: confirmed Connected Research Workbench — 2026-09-08

Source visual truth: `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-82f085f7-6688-4bf4-84f2-fb3909ae6757.png`.

The previous editorial design was selected by incorrectly mapping generation-completion order to display order. The user rejected that mapping and explicitly confirmed this three-column image. All earlier acceptance below is historical, not acceptance of the current design.

### Comparison target and iterations

Artifacts: `output/home-workbench-20260908/`. Source and wide implementation are both 1487×1058 pixels at a 1487×1058 CSS viewport, density 1. No browser chrome, framing, stretching or density conversion. English Home, dark Graphite, historical cutoff 2026-06-01, Bill Ackman / Q1 2026 / MSFT. Each composite contains source left and implementation right in the same image.

1. `01-first.jpg` / `02-reference-comparison.png`: [P1, fixed] the old two-panel editorial architecture was replaced with the confirmed investor / reported holdings / selected research tracks. [P2] extra vertical spacing in the research header, tabs and price region displaced Continue research below the source's first-view position. The generic ticker-first header also weakened company identification. These findings blocked initial visual acceptance.
2. `06-final-desktop.jpg` / `07-final-comparison.png`, focused `08-detail-comparison.png`: reduced cumulative research spacing, made company name primary with exact ticker beneath, tightened shelf margin, retained actual full-history curve and visible dates. The saved-research shelf is now visible at the wide source viewport. Opened both the full composite and readable right-region composite, not separate images alone.
3. Functional QA: ALAB at the preview cutoff has no PIT research. Initial missing-state view `12-mobile-alab-research.jpg` left the filing button inside the available-model branch. [P2, fixed] source filing is now accessible with a missing model and on the position tab; claim history remains independent of research availability. `17-confirmed-missing-pit.jpg` then exposed a real contract mismatch: the API returns HTTP 422, not the fixture's 404, with `no_pit_research_at_date`. The known code now classifies either 404/422 as unavailable coverage, without a misleading Retry; transient failures retain retry. The regression fixture now uses the actual 422 response contract. Rebuilt browser DOM and `19-missing-pit-final.jpg` confirm the explicit missing-PIT message, View filing, Position history, and absence of Retry. This capture had a temporary browser viewport scaling artifact (content at half size with blank surroundings); it is functional evidence only, excluded from pixel-fidelity comparisons.
4. `20-workbench-ready.jpg` and combined `21-delivery-comparison.png` were opened and checked after the final rebuild at the original 1487×1058 viewport. The intended wide composition, visible saved-research shelf, exact selected stock and complete real curve remain intact. The earlier readable right-region comparison `08-detail-comparison.png` is unchanged by the error-contract-only correction. No actionable P0/P1/P2 issue remains in this Home scope.

### Required fidelity surfaces

- **Typography:** existing application sans-serif family and CJK fallback, 38px desk title, 28px selected company name, 34px price figures, 18px section headings, 22px financial metrics. The prior serif editorial hierarchy is removed from this page. Legal names and exact ISO dates are deliberately retained instead of invented short names; names can wrap in the compact investor rail, while holding secondary names ellipsize without hiding ticker or weight.
- **Spacing/layout:** existing 216px navigation, three linked tracks separated by rules, six visible ruled holding rows with a bounded scroll list for remaining extraction records, selected mint edge/fill, right curve and CTA, lower saved research. No generic dashboard-card grid or portrait hero. 1280×720 scrolls vertically; 390×844 uses Investor/Holdings/Research steps with persistent navigation. Viewport captures `10`–`16` include reachable lower mobile actions, not just a first screen.
- **Colors/tokens:** retained Graphite dark surfaces, original border/neutral hierarchy and mint selection/actions. The reference's subtle decorative glow and gradient button are intentionally represented by existing flat accessible app controls; financial colors do not imply a recommendation. The actual shared chart painter and its price/model colors remain unchanged.
- **Image quality/assets:** canonical ThesisForge mark, verified existing manager portraits and issuer PNG logos; Material icons. No generated replacement financial images, synthetic chart points or hand-drawn logo substitutes. AMZN/UBER keep the dark backing needed for their supplied white-letter transparent assets. Different logo variants in the mock are not authoritative replacements for canonical issuer assets.
- **Copy/content:** source-backed manager, accession, claim, quarter, weight, public dates, prices, published blended value and three real metrics. Margin labels explicitly say TTM to avoid the mock's ambiguity. The curve is not an editable standalone FCFE result or a manager-entry valuation. Missing extract is not zero/new buying. Loading, transient failure, missing PIT, unavailable source and empty manager/claim states have explicit copy.

### Functional verification

- 208 Flutter tests passed, including 76 workflow tests; 33 backend workflow tests passed. Full static analysis: no issues. Existing repository i18n audit and private web build pass; the new part's bilingual coverage is additionally verified by populated widget tests and browser checks rather than overstating the literal scanner's scope. `git diff --check` passes.
- Tests cover exact ticker/claim and manager identity, quarter retention and future exclusion, response ordering across ticker/manager/cutoff changes, no substituted stock, missing PIT versus transient retry, disclosure recovery, source dialog, search, valuation origin, alerts, no implicit decision writes, responsive EN/ZH. The previously wrong independent-example tests were rewritten to verify connected selection rather than discarded without replacements.
- Browser: Ackman → AMZN → Position history → Q4 2025 → AMZN valuation. Evidence `03-amzn-position.jpg`, `04-amzn-prior-quarter.jpg`, `05-amzn-valuation.jpg`: Q1 11,451,981 shares, Q4 9,607,824, and correct Q4 filing context at valuation entry. Dates/quarters are real source observations, not a recommendation.
- Browser: original MSFT filing dialog (`09-filing-source.jpg`) has correct manager, accession and dates, with only an actual HTTPS SEC source eligible to open. No external filing was fabricated or published.
- Browser: mobile investor selection auto-advances to holdings and stock selection advances to research; ALAB missing model still allows real Chinese position history; MSFT Chinese chart, metrics, filing and valuation buttons are visible with vertical scrolling (`10`–`15`). Compact desktop `16-compact-desktop.jpg` retains all three tracks and navigation. Widget checks cover 1487, 1280, 1024 and 390 widths across the existing pages.
- Retrieved browser logs contain only bootstrap debug messages; no unexpected error-level entries. Missing ALAB is an explicit API data response, not a browser crash.

### Scope and remaining checks

Local Home workflow implementation only, using the existing paid/PIT runtime API. No production rollout, Git commit, new financial model, paid-data refresh, or full-universe coverage certification. Research API returned `no_pit_research_at_date` for ALAB at 2026-06-01; it was not filled with a made-up valuation. User comprehension/conversion uplift is not measured. Portfolio/Research/Discover engines and existing saved records remain owned by their prior implementation.

P3 follow-up: the generated reference uses slightly larger portrait and action treatments; this implementation reuses app-size assets and button styles. Full source-company names and separate ISO dates create small text-rhythm differences. These do not change the selected three-column workflow or hide identities/actions.

Checklist: confirmed image → linked implementation → combined source comparison → spacing fixes → exact identity/date guards → regression tests → mobile and source checks → final 422-state and rebuilt render recheck.

final result: passed

The final preview is running locally, showing Bill Ackman / Q1 2026 / MSFT. Remaining P3 visual differences and historical-model coverage limits are explicitly stated above, not represented as completed platform-wide work.

---

## Historical run: editorial Home (incorrectly mapped option, rejected) — 2026-09-08

Source visual: `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-07595ad2-6860-4230-b6dc-5b9976197be0.png`.

### Comparison history

All artifact names below are relative to `output/home-redesign-20260908/`. Source 1486×1059 is normalized with aspect-preserving containment to 1487×1058; implementation uses a 1487×1058 CSS viewport and screenshot pixels at density 1. State: Home, English, historical cutoff 2026-06-01, Ackman/AMZN and independent MSFT example. No browser chrome is included. Source text is a design reference, not financial source data.

1. `14-editorial-render.jpg` and combined `15-comparison-initial.png` (source left, implementation right): [P2] header controls and loose list rows pushed saved research below the viewport; [P2] editorial title and portrait were undersized. Fixed with compact date/search, ruled single-line rows, tighter spacing, a 60px headline and 190px portrait. The early legacy-screen build caused by an omitted local feature flag is excluded from visual acceptance.
2. `19-editorial-final.jpg`, combined `20-comparison-final.png`, and focused `21-comparison-detail.png`: the main-region hierarchy and visible saved-research strip are restored. [P2] the bundled AMZN and UBER marks have transparent white lettering, disappearing on the existing pale logo container. Inspecting both source PNGs confirmed the issue. Home now uses a dark backdrop for these two original marks; other terminal uses and asset files are unchanged.
3. `26-editorial-delivery.jpg`, combined `27-comparison-delivery.png`, and focused `28-comparison-delivery-detail.png`: opened together and reviewed at normalized full view and readable holding/CTA/list detail. The logo contrast issue is fixed.
4. [P2, fixed] Additional short-desktop check `29-editorial-compact.jpg` at 1280×720 found the 60px title wrapped to three lines and pushed the primary CTA below the fold. A scoped 44px title / 144px avatar breakpoint restores the two-line title and visible CTA in `30-editorial-compact-final.jpg`. The before/after pair was opened together as `33-compact-before-after.png`. Final 1487×1058 capture `31-home-ready.jpg` was again compared with the source in `32-source-ready-comparison.png`; the selected wide composition remains intact. No actionable P0/P1/P2 mismatch remains in the delivered Home scope.

### Required fidelity surfaces

- **Typography:** locally bundled DM Serif Display supplies the cream editorial headings (60px wide / 30px compact hero). Existing UI typography stays on controls and data. Chinese uses the existing CJK fallback at medium-bold weight. Main title wraps to two lines like the selected source; exact font rasterization is not claimed. Secondary data type is more compact than the mock to retain real provenance and both languages.
- **Spacing/layout:** preserve the existing left rail, dominant investor brief, separating rule, narrower valuation column and ruled holdings. Saved research is visible at 1487×1058; shorter screens scroll naturally. Mobile uses Guru / Price & value tabs rather than compressing two columns. Date controls wrap and CTA text flexes; full tests caught and verified fixes for both synthetic-font overflows.
- **Colors:** existing Graphite surfaces and mint actions, cream headlines, muted price curve and mint published-value curve. The existing flat action treatment is retained rather than introducing the mock's glow. These colors do not imply investment suitability.
- **Image quality:** actual ThesisForge mark, canonical manager portraits, company PNGs and Material icons. No generated or code-drawn substitute logos. White-ink logo backgrounds are corrected only on Home. [P3] the canonical 144px manager portrait is softer than the generated reference at the 190px desktop slot; a verified higher-resolution source could improve it later.
- **Copy/content:** dynamic manager, quarter, claim identity, shares, weight and dates; missing prior extraction is not zero or a confirmed new position. Corporate-action and independent-valuation caveats are deliberate correctness additions. The real full 66-node / 900-price MSFT series remains intact; its geometry is not altered to match the mock. Published blended value remains distinct from editable standalone FCFE.

### Functional and responsive verification

- **202 Flutter tests passed**, including 70 workflow tests. Seven regressions were added in this editorial iteration: adjacent shares, missing prior, mismatched claim, mismatched manager, retry, late-cutoff response, and configurable logo backdrop preserving issuer identity.
- **33 backend workflow tests passed**; no backend or financial-math changes. Full `flutter analyze`, `npm run audit:i18n`, final private web build and `git diff --check` passed.
- Browser: Home → exact Bill Ackman / Q1 2026 / AMZN history → AMZN research; Home → MSFT editable valuation. Captures `17-trace-amzn.jpg` and `18-msft-value.jpg`. Filing and ticker context remain intact.
- Browser: change Guru to Gavin Baker (ALAB, 1,611,194 → 3,365,787 shares); independently switch MSFT to ISRG ($412.26 price / $415.95 published value, separately dated). These are historical source observations, not fresh investment recommendations.
- Mobile 390×844: `22-editorial-mobile-en.jpg`, `23-editorial-mobile-value.jpg`, `24-editorial-mobile-zh.jpg`, `25-editorial-mobile-holding-zh.jpg`. Both panel tabs and language toggle work; Chinese saved actions read 放弃 / 投资. Shared layout unchanged by the final logo-only correction.
- Returned final browser logs contained bootstrap debug messages and no error-level entries. Browser checks made no new scenario, decision or follow writes.

### Boundaries and acceptance

This is the selected Home implementation inside the existing app, not a redesign of every other page. Private localhost only; production login and deployment are not certified. Historical source coverage and valuation economics were not refreshed. No measured user-comprehension or conversion uplift is claimed. Existing saved QA records are retained, not fabricated for the new design.

Checklist complete: source comparison → layout corrections → identity and date guards → responsive/bilingual checks → regression tests → final visual comparison. Remaining portrait sharpness is P3 follow-up polish.

final result: passed

Earlier QA below is historical, not acceptance of this selected design.

## Latest run: Home clarity and first-use redesign — 2026-09-08

User-directed change: the provided Home screenshot was too empty and did not explain what to do. This is a scoped redesign of that existing page, not a new visual theme or a faithful clone of its empty layout.

### Evidence and comparison history

- Source: user screenshot `codex-clipboard-1a99700e-6577-4e8d-ab64-523b0cfd5bf8.png`, plus the current-run capture `output/home-redesign-20260908/01-before.jpg`.
- Normalized comparison: current Home route, English, cutoff 2026-06-01, 1487 × 1058 CSS viewport and screenshot pixels, 1:1 density. The before capture and `02-home-first-pass.jpg` were opened together. After corrections, the before capture and `06-home-final.jpg` were opened together again at the same viewport, date and user data state. The final language-only correction was rebuilt and checked separately.
- The revised content order intentionally differs: a concrete product promise and company search; source-backed Guru holdings beside a valuation example; then saved research. Existing rail, palette, assets and calculation engines remain unchanged.
- [P1, fixed] An empty review queue occupied the dominant region without demonstrating the product. It is now a short secondary status. A populated queue remains above discovery content and expands to every original review entry, including missing-data warnings.
- [P1, fixed] Abstract entry cards hid the actual task. Home now shows named managers, dated common-share holdings, reported weights, stock identities, actual prices and published blended-value observations. Clicking a holding selects its manager / filing / ticker in the existing trajectory view. The independent valuation example is explicitly labelled, not attributed to the selected Guru.
- [P2, fixed] First mobile pass stacked the full holdings panel before valuation. `03-mobile-first-pass.jpg` and `04-mobile-revised.jpg` were opened together at 390 × 844. Compact Home now exposes Guru holdings / Price & value switches before the panels; the date row is compressed. `05-mobile-value.jpg` records the reachable alternate state.
- [P2, fixed] The new valuation CTA initially used an unsupported section key and landed on Overview. It now opens the actual `value` section. Added tests assert the five-year cash-flow workspace, not merely the issuer name, and the browser confirmed it.
- [P2, fixed] A shared top-level action formatter left Pass / Invest untranslated in the new Chinese footer. The page now explicitly uses the workflow formatter. The final Chinese browser snapshot and `10-mobile-zh-research.jpg` show 放弃 / 投资. Both-language tests assert a saved Watch / 观察 entry.
- Additional captures: `07-holding-route.jpg` (AMZN trajectory with the exact entry filing); `08-home-mobile-zh.jpg`; `09-home-compact.jpg` (1280 × 720). At short desktop heights the page scrolls naturally; holding rows are actionable before scrolling. No persistent controls are clipped.

### Required fidelity surfaces

- Typography: existing Inter stack retained, scoped 34px desktop / 27px compact headline, 19–20px panel and issuer hierarchy, 12–14px body text. Dense dates and source annotations remain smaller; important actions are semantic buttons/chips. No exact raster-font fidelity or formal WCAG claim.
- Spacing: original 216px rail preserved; two equally weighted content regions with 20px separation, original 8px card treatment. The oversized empty panel and isolated lower entry cards are removed. Mobile uses a single switchable panel, not a squeezed desktop row.
- Colors: original Graphite palette, mint action / valuation accents and muted market-price line; no new gradients or decorative backgrounds. A mint model value is not an investment recommendation.
- Image quality: canonical manager portraits, company logos and Material icons; no fabricated asset substitutes. The chart uses the existing painter with actual dated observations filtered to the recent three-year view, without interpolation or synthetic points.
- Copy: explicit tasks, reported-weight and delayed-disclosure context, separate price / model dates, published blended value distinguished from editable standalone FCFE. Insufficient data displays an unavailable state, never a zero valuation.
- Full paired screenshots made the main labels and proportions legible; additional phone and 1280px screenshots resolved compact-layout questions. A separate crop was not required. Chinese footer correction also received a focused scrolled capture.

### Verification

- Full Flutter suite: **195 passed**, including **64 workflow tests** (12 added for Home).
- Backend workflow suite: **33 passed**, no backend changes in this iteration.
- Targeted analysis: no issues. Final private web release build: passed. Whitespace check: passed.
- New tests cover bilingual desktop / mobile, exact holding-to-quarter navigation, direct valuation entry, option exclusion, no implicit writes, blank / typed search, failed-example retry, late-response rejection, date invalidation and preservation of every review alert.
- Real browser checks cover manager switching, ISRG / MSFT example switching, Home → AMZN trajectory, mobile Home → MSFT editable valuation, bilingual compact controls and translated saved actions. Final returned logs contained bootstrap debug entries, no error-level entries.
- Browser review caused no new scenario, decision or follow writes this turn. Existing LOCAL QA records from the preceding run are retained.

### Limits / follow-up

- The three featured managers and three valuation examples are editorial entry choices, not personalization, opportunity rankings or newly verified investment recommendations.
- Source data remains a bounded released extract with its actual historical cutoff; this run does not refresh paid data or certify every issuer's valuation economics.
- Local preview only; production authentication and deployment are not included. The previous full workflow limitations still apply.
- Improvement in comprehension has not been measured with external users; it is a source-grounded design correction, not a claimed conversion uplift.

final result: passed

---

## Current run: product workflow implementation — 2026-09-08

Scope: the local core workflow from the product redesign blueprint: Home → Discover → dated Guru holding → Research / Valuation → saved decision → Then vs Now review. This result does not certify every page in the 17-page blueprint, production authentication, or deployment.

### Visual comparison and corrections

- The selected Graphite reference below and `output/product-build-20260908/04-msft-value-final.jpg` were opened together at 1487 × 1058, English, MSFT, cutoff 2026-06-01, Base scenario. Despite its filename, capture 04 is the first comparison, not the final result.
- [P2, fixed] The forecast table occupied only part of its available desktop column. A width constraint now fills the workspace; narrow screens retain intentional internal table scrolling.
- The reference and revised `07-msft-value-revised.jpg` were opened together again at the same viewport and state. The table width issue is resolved. The later blueprint deliberately moves the historical curve to Overview and uses a five-year worksheet in Valuation; this is not a pixel-identical replication of the earlier mock.
- [P2, fixed] On mobile, inputs initially pushed the valuation result below a long worksheet. `05-mobile-before.jpg` versus `06-mobile-value-revised.jpg` records the change to results first, then editable forecasts.
- Final release captures: `08-msft-overview.jpg`, `09-home.jpg`, `10-strategies.jpg`, `11-discover-final.jpg`, and `12-discover-mobile-zh.jpg`. Desktop captures are 1487 × 1058; mobile is 390 × 844. These are actual browser screenshots, not generated charts or retouched financial data.
- The existing Inter stack, graphite surfaces, mint accents, canonical company / manager assets, and Material icons are retained. Main body text is 14px, source metadata 12px, and page titles 22px. No exact font-raster or pixel-fidelity claim is made.
- Desktop hierarchy, compact company header, source breadcrumb, responsive manager grid, and mobile wrapping were visually checked. No page-level horizontal clipping was observed in the checked states. Wide forecast tables scroll internally by design.

### Functional evidence

- Discover exposes 29 actual managers at the tested cutoff and links real source-backed fundamentals; no invented opportunity metrics are used.
- Browser journey: Bill Ackman → 2025 Q4 filing → AMZN → Shares / Weight history → Research → edit forecast → save scenario → record Pass → Then vs Now → record Maintain. The exact filing accession `0001172661-26-001091` is retained across research navigation, direct URL reload, and the immutable decision record.
- Missing extracted holdings remain “Not in extract”, not zero. Selected-quarter history and linked research do not silently switch to the latest quarter.
- Scenario edits invalidate the saved-version association. Decision actions and rules require explicit selection; Pass does not require a fictitious position. Leaving an edited sandbox requests confirmation.
- Three explicitly labelled local QA ledger events were written: one scenario, one Pass decision, and one Maintain review. Read-only SQLite inspection verified the dated provenance. The original decision was not overwritten. These are local QA records, not investment recommendations or production user activity.
- Original and last-confirmed Then vs Now comparisons use their respective frozen assumptions on both dates. Additional position actions require an active position.
- Final browser checks also covered MSFT Overview, Inspect inputs open / hide, Home, Strategies, and English ↔ Chinese on mobile. No error-level entries were observed in the returned final browser logs.

### Final verification

- Full Flutter suite: **183 passed**, including **52 workflow widget tests**.
- Backend workflow suite: **33 passed**.
- Targeted Flutter static analysis: no issues. Final release build: passed. `git diff --check`: passed.
- A regression in attempted scroll-offset persistence caused an ExpansionTile type error. Tests caught it; the outer scroll key was reverted to ValueKey before the final passing tests and release build. Automatic scroll-offset restoration is not claimed.

### Delivery boundaries

- This is a private localhost build using isolated runtime data and a separate QA decision ledger. The authentication bypass must never be published.
- Existing full Guru backtests, free-range controls, and the industry graph remain in the legacy terminal, reachable with a cutoff warning; they have not been recreated inside the new workflow.
- Guru extraction coverage is bounded and explicitly labelled. Missing peer analytics and other unavailable metrics are not fabricated.
- Production login-return behavior, every blueprint edge case, and a formal WCAG audit are outside this local verification.

Current run final result: **passed for the delivered local core workflow and visual scope**.

---

## Archived run: initial Graphite visual implementation

Source visual truth: `/Users/yudonglu/.codex/generated_images/01a053a9-c799-71d2-aa96-f1299e48de42/exec-db3a7a95-ad30-4353-9268-ff38a572ed3d.png`

Scope: selected Option 1 implemented inside the existing Flutter investment workflow. The legacy terminal, financial engines and persistent decision ledger are retained. This is a private localhost preview, not a production release.

## Comparison history

### Pass 1

- Source and browser screenshot opened together in one comparison input.
- Implementation: `output/investment-workflow-20260908/graphite-qa-1.jpg`.
- Viewport: 1487 × 1058 CSS pixels; source and screenshot: 1487 × 1058 pixels. Effective screenshot density 1:1; no browser chrome or canvas-padding normalization necessary.
- State: English, graphite, MSFT, information cutoff 2026-06-01, Valuation, Base scenario. Actual company name is Microsoft Corporation rather than the mock's shortened Microsoft.
- [P2] Chart legend and axis labels are smaller than the source, reducing research readability. Increase legend from 13 to 16 and opt this workflow into 13-pixel chart labels, preserving legacy defaults.
- [P2] Separate desktop price-date line and chart height push fundamentals about 60 pixels below the intended position. Put the dated source alongside Price on desktop and reduce chart height to 370 pixels maximum; retain stacked metadata on mobile.
- [P2] Compact rate inputs are unnamed in browser accessibility output. Add explicit semantic labels, keeping the uncluttered underline style.
- Layout geometry already matches the major 232-pixel rail / broad chart / compact scenario column. Real chart observations must not be altered to copy the generated line shape.

### Implementation verification before visual pass

- Fixed intrinsic measurement of a LayoutBuilder by using an ordinary top-aligned row.
- Brand and rail labels now tolerate narrow widths and the Flutter test font; chart legend can wrap.
- 45 workflow widget tests pass across English/Chinese and 1487×1058, 1280×720, 1024×768, 390×844; including exact original ratio preservation, percentage conversion, detailed year edits, confirmation/cancel, navigation and date invalidation.
- Full Flutter suite: 176 passed. Static analysis: no issues. Backend workflow suite: 29 passed. Final private release build passed.

### Pass 2 and final confirmation

- Revised capture `output/investment-workflow-20260908/graphite-qa-2.jpg` was opened together with the source in a single comparison input at the same 1487×1058 viewport, English/MSFT/2026-06-01/Base/Valuation state.
- Final build capture `output/investment-workflow-20260908/graphite-final.jpg` was again opened alongside the source after date-invalidation fixes. Geometry and values remain unchanged from Pass 2.
- Pass 1 P2 findings resolved: larger 16px legend, 13px chart annotations; price-date now inline on desktop; fundamentals sit within the initial viewport; all three rate textboxes now expose their distinct names in accessibility output.
- Full-view evidence shows the fixed rail, dominant actual-data chart, scenario column, visible dates, numeric hierarchy and primary save action. No additional crop was necessary: logo edges, labels, percentages and buttons are legible at the matched 1:1 viewport. The browser's native screenshot bytes are JPEG (filenames now reflect that); no image processing, generated plot replacement or financial retouching was performed.
- Primary browser checks: Overview→Valuation; Ke 9%→10% updates standalone value $178.02→$154.02 while published value stays $313.54; Base restores the initial result; Save opens explicit ownership confirmation with disabled submit; Cancel writes nothing; EN↔中文; Home→Then vs Now opens the existing ISRG decision; changing the Home cutoff invalidates stale research; rebuilding/reloading retains the correct dated data.
- Historical chart semantics remain 66 valuation nodes / 900 price observations in both the Base and edited MSFT scenario states.
- Mobile evidence: `output/investment-workflow-20260908/graphite-mobile-en.jpg` and `graphite-mobile-zh.jpg`, 390×844. Chart and scenario stack, labels wrap, all five navigation entries and language switch remain reachable. Vertical scrolling is expected; no page-level horizontal clipping.
- Additional desktop states: `output/investment-workflow-20260908/graphite-home.jpg`, `graphite-review.jpg`. Existing historical ISRG decision and v2 review remain readable; no new financial ledger writes were made by visual verification.
- Browser log inspection found no error entries for the tested release interactions; only bootstrap/debug entries and earlier dev-loader informational logs.

## Fidelity surfaces

- Typography: existing Inter family retained; numeric display hierarchy, readable 16px main labels, 13px chart labels and wrapping inspected in the combined source/final comparison. Runtime font rendering is slightly tighter than the generated mock, acceptable without changing the established font assets.
- Spacing/layout: fixed rail and responsive split; no fixed-height content truncation. Compact layouts stack chart before scenario; both remain scrollable.
- Colors: scoped graphite palette, mint accent, hairline slate dividers. Final source comparison preserves the same contrast hierarchy without copying generated background texture. Legacy palette is not replaced.
- Image quality: canonical ThesisForge raster and existing stock-logo assets reused without redrawing. The Microsoft stock-logo asset retains its existing white tile rather than the generated mock's transparent treatment.
- Copy/content: actual dated PIT values and calculation outputs only. Parent FCFE and published blended value are distinct. Year 1 margin explicitly labelled; detailed five-year inputs retained.

## Implementation checklist

- [x] Implement selected layout in existing product.
- [x] Preserve calculation precision and immutable save ownership check.
- [x] Run frontend and backend regression checks.
- [x] Repeat same-state visual comparison after Pass 1 fixes.
- [x] Verify final browser desktop/mobile interactions and console output.

## Remaining differences / follow-up polish

- [P3] The generated reference abbreviates Microsoft and dates. The real app retains the full issuer name and unambiguous ISO dates; this is deliberate source clarity, not missing content.
- [P3] Existing company-logo tiles and Material outlined icons differ slightly from generated marks. Canonical source assets and a consistent shipped icon library are deliberately retained.
- [P3] Home and Review inherit the rail, graphite surfaces and typography, but retain their established record/list structures; no new data or missing analytics were invented to fill the page.
- The full generated curve shape is not a source of truth. The code-rendered curve follows the original historical observations, without smoothing or synthetic points.
- Production authentication, deployment and the broader V1 limitations in the delivery report are not certified by this local visual pass.

final result: passed

---

## Portfolio visual redesign — 2026-09-11

Final result: **passed for the local Portfolio presentation and interaction scope**.

The user asked for an independently chosen redesign of the portfolio section and
its charts, without a design-selection question. Product Design was used to
choose one source-grounded visual target, then implement it in the existing
Flutter workspace. Real account data, routing, financial calculations and saved
privacy preferences were retained. No database refresh, trade, strategy run or
production deployment was performed.

### Visual target and comparison

- Target: `output/portfolio-redesign-20260911/visual-target.png`; generated design
  reference only, not a source of financial values or a bitmap served by the app.
- Target and rendered page were opened together in the same comparison input,
  including a final **1672 × 941** exact-size comparison, English / Portfolio
  Overview / privacy on / 2026-09-10 research cutoff. Also checked 1280 × 720.
- Final reference-size capture:
  `output/portfolio-redesign-20260911/portfolio-desktop-final.jpg`.
- Additional evidence: `portfolio-pnl.jpg`, `portfolio-movers-valuation.jpg`,
  `portfolio-mobile-en.jpg`, `portfolio-mobile-chart.jpg`,
  `portfolio-mobile-zh.jpg`, and `portfolio-mobile-allocation.jpg` in the same
  output directory. Mobile captures use **390 × 844**.
- Typography uses the shipped app font and numeric hierarchy. Slate surfaces,
  14px card radii, consistent spacing, four equal-height wide-screen metrics,
  a dominant account-history chart and a secondary allocation ring follow the
  target. Existing company logos and Material icons are retained.
- Deliberate differences from the illustrative target: actual reported values
  and an unsmoothed 261-observation history; explicit data dates, account access,
  privacy control, rate denominators and borrowing; Holdings/Sectors toggle in
  place of a redundant small search box. Winners/losers precede detailed risk.
  The current complete history is shown rather than inventing the target's line.

### Findings and repairs

- [P1/P2, resolved] A separate global cutoff row and explanatory copy above the
  chart pushed the curve out of the first viewport. The cutoff now sits beside
  the Portfolio heading; the chart is part of Overview, with compact responsive
  controls and visible explanations below it. Full chart visible at reference
  size; shorter laptop views scroll normally.
- [P2, resolved] Ragged metric-card heights and a vertically stacked desktop
  ring/legend. Metrics align; the ring grows with available space, and stacks
  with its touchable legend on narrow screens or enlarged text.
- [P2, resolved] Compact chart controls overflowed under Flutter's test font.
  Bounded flexible columns now wrap safely. Follow-up widget tests passed.
- [P2, resolved] Short ranges repeated month-only tick labels. Ranges up to 120
  days now use month/day ticks; negative selected P&L is colored red.
- [P2, resolved] New GOOG chart links initially opened an unavailable GOOG
  research page. Navigation now follows only the API's explicit GOOGL model
  link, with a visible shared-model explanation. The holding's identity, own
  price and weights are unchanged. Browser verified that the link opens GOOGL
  Valuation; a regression fixture covers linked and unlinked share classes.

### Functional and financial verification

- Real NAV, realized P&L and cash-adjusted P&L modes work. Browser verified a
  one-month range rebases P&L, and ArrowLeft selects the previous observation.
  Daily MTM unavailability is not relabeled as today's actual P&L.
- Ring legend selection highlights the held security, displays its weight and
  opens research. Sector switching works; unknown classifications remain shown.
  Negative cash/shorts are excluded from this positive non-cash denominator,
  with borrowing presented separately. Tail slices are aggregated, not dropped.
- Winners/losers and valuation bars share a zero baseline and common scale
  within each comparison. Missing model values are not replaced with zero.
- Privacy is preserved across Home/Portfolio and reloads. Widget tests cover
  public/private modes, all history modes, currency changes, missing cost bases
  and nonpositive NAV denominators. Painter input in privacy mode contains
  percentages, not hidden account amounts. Browser QA kept the owner's existing
  privacy-on preference and made no user investment edits.
- English and Chinese mobile pages, chart controls, scroll, allocation legend
  and date slider were inspected. Widget tests additionally cover 150% text.
  Existing Guru comparison and shared Home history remain functional.
- Final checked browser warning/error log was empty. Temporary viewport
  overrides were reset and the English Portfolio overview restored.

### Checks and boundaries

- Full Flutter suite: **518 passed**. After the final tick-label/color polish,
  **31 targeted Portfolio/Home/privacy tests passed** again.
- `flutter analyze --no-pub`: no issues. Release preview build passed.
- `audit:i18n`, `verify:ontology-module`, `test:ontology` passed (3 Python and
  22 Node tests). `git diff --check` passed.
- Existing missing risk-price coverage remains explicit (no synthetic beta,
  Sharpe or SPY simulation). This redesign does not certify those source data,
  historical account performance reconciliation, or production authentication.
- [P3, intentional] Detailed financial provenance makes the live panels taller
  than the mock; smaller screens use vertical scrolling. No content is clipped
  to force the entire dashboard into a fixed-height screenshot.

Final result: **passed**.

# Design QA — Opportunities and Guru copy simulation (2026-09-20)

## Scope

- Opportunities remains the primary Discover tab and now summarizes quarterly institutional activity as New positions, Most increased, Most reduced, and Exited positions.
- Selecting a category changes the ranked security list and the exact manager-level evidence shown for that action.
- Selecting a Guru in the full directory expands an audited disclosure-date copy simulation against SPY inside that Guru's row.

## Reference comparison

- Reference: the supplied All Gurus directory screenshot with an expanded Evan McGoff row.
- Rendered implementation: local Flutter web app at 1440 × 1000.
- The implementation retains the reference hierarchy, portrait treatment, highlighted row, teal accent, metric columns, and inline study actions.
- The expanded row adds the requested curve and four compact performance metrics without changing the surrounding directory interaction model.
- Opportunities uses the same panel, typography, spacing, status-color, and evidence-detail language as the existing ThesisForge UI.

## Responsive and interaction checks

- Desktop 1440 × 1000: four action cards, company ranking, evidence pane, and expanded Guru curve render without overflow.
- Mobile 390 × 844: navigation, action-card carousel, tabs, and filters remain reachable and readable.
- Verified category selection for Most increased and Exited positions.
- Verified historical-quarter switching from 2026/Q2 to 2025/Q4.
- Verified Guru selection for Evan McGoff and a populated 2021–2026 Portfolio vs SPY curve.
- Verified a fresh browser tab reports no console warnings or errors after page load and interaction.

## Data and disclosure checks

- Activity labels come from reported share-count changes and do not claim execution price or intra-quarter timing.
- Missing rows are not classified as exits.
- Portfolio weights are identified as disclosed common-long book weights, not fund AUM.
- Guru curves use audited SEC acceptance/filing dates, execute on the first tradable close, retain unavailable weight as cash, and are explicitly labeled as simulations rather than fund NAV.
- Sharadar quarter-end holdings are not treated as public knowledge dates; when the audited SEC-timestamp cache is unavailable, the simulation continues to fail closed.

## Validation

- Flutter analyze: passed.
- Flutter regression suite: 143 tests passed.
- Backend targeted suite: 34 tests passed.
- Desktop and mobile browser inspection: passed.
- Fresh-tab browser console inspection: passed.

final result: passed
