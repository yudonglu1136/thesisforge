# ThesisForge Agent Operating Contract

This repository is the single ThesisForge product root. Guru research,
fundamental analysis, valuation, portfolio, strategy, and the local Fact OS are
modules of this one product; they are not separate projects. Follow this
deployment split unless the user explicitly changes the architecture.

## Single-Root And Append-Only Data Contract

- The only local project root is `/Users/yudonglu/Documents/thesisforge`.
  Agents must not create sibling clones, worktrees, `*-release`, `*-refresh`,
  `*-candidate`, or dated project copies under `Documents`. Use a branch in this
  repository, a bounded directory under `tmp/`, or `/private/tmp`, and remove
  temporary artifacts when the task finishes.
- Do not copy a database or the full `data/fact_os` tree to run an experiment.
  SQLite experiments must use the backup API into a bounded temporary file;
  Parquet readers must pin the published manifest. Never put SQLite, Parquet,
  provider archives, or whole data trees under `output/`, `docs/`, or a new
  project directory.
- `data/fact_os/raw` is immutable and content-addressed. A byte-identical
  response reuses the existing object and adds only a small receipt. Do not
  create a second raw file, rename it as a new download, or rewrite it in place.
- Canonical facts are append/revision safe: write by the documented natural key,
  preserve older observations, and publish a new Parquet generation only when
  the canonical content changes. Re-running the same input must be a no-op for
  facts, Parquet bytes, and current manifests. Never use full-table replacement
  or `INSERT OR REPLACE` to simulate append-only ingestion.
- Derived Parquet generations are immutable. Publication is manifest-last and
  atomic. Garbage collection may remove only unreferenced generations after the
  retention window; raw archives are never GC targets.
- There is one public runtime database:
  `server/data/guru-analysis.sqlite`. User portfolio stores live only under
  `server/data/user-portfolios/`; distinct recovered private snapshots may live
  only in the content-addressed `server/data/private-recovery/by-sha/` vault.
  Never copy private stores into fixtures, output, release bundles, Fact OS, or
  another project.
- Every sync or migration must hold the Fact OS writer lock, verify natural-key
  uniqueness, compare pre/post row counts and oldest dates, run a same-input
  replay, and write a receipt under `data/fact_os/audit/`. A retry must resume or
  no-op; it must not redownload or duplicate already accepted bytes.
- Before declaring storage work complete, run `npm run audit:storage-layout`
  and the full Fact OS storage audit. A new write expected to exceed 2 GiB needs
  an explicit size estimate, target path, retention plan, and free-space check.
- The external Vercel project is named `thesisforge`; never recreate the retired
  local `fundamental-analysis` or `guru-intelligence` project roots.

## Deployment Ownership

- Frontend is deployed on Vercel.
- AWS Elastic Beanstalk is backend/API only.
- Browser traffic for `https://www.thesisforge.tech/` must resolve to Vercel, not Lightsail or Elastic Beanstalk.
- Vercel serves the Flutter web build from `dist/`.
- Vercel proxies only `/api/*` to the AWS Elastic Beanstalk API.
- After a production deploy, both `https://www.thesisforge.tech` and `https://thesisforge.tech` must alias to the same latest Vercel deployment.
- Production deployments belong to the Vercel project `thesisforge` and the AWS
  Elastic Beanstalk application `thesisforge-api`; both public domains must
  remain on one verified `trunk` deployment.
- A split alias is a release blocker. After every production deployment, run
  `vercel inspect` for both public domains and confirm that they return the same
  deployment ID and URL. If either domain is stale, explicitly assign both
  domains to the verified deployment with `vercel alias set`; never update only
  one of them.
- AWS API CORS must allow both `https://www.thesisforge.tech` and `https://thesisforge.tech`; stale or diagnostic frontend builds can otherwise receive an HTML 500 from Express instead of JSON.
- Do not deploy the primary frontend by rsyncing `dist/` to Lightsail.
- Do not add DNS `A` records for `www.thesisforge.tech` or `thesisforge.tech` that point to the Lightsail IP.
- Keep `api.thesisforge.tech` or the EB CNAME available for backend diagnostics only.

## iOS / App Store Work

- The repository is Flutter Web first and now includes a generated Flutter iOS
  shell in `ios/`. Do not delete or regenerate it casually; preserve local
  signing, icon, launch image, auth callback, and bundle ID work.
- Before generating or implementing the native iOS app, read:
  - `docs/ios-app-store-readiness.md`
  - `docs/ios-product-design-brief.md`
  - `docs/ios-asset-inventory.md`
- The iOS app should preserve the same backend contract: authenticated API calls through the production HTTPS API contract, user-specific Supabase identity, and encrypted IBKR/Yodlee credentials stored only on the backend.
- Add Sign in with Apple, in-app account deletion, privacy disclosures, and a reviewer demo path before App Store submission.
- Bundle ID is `tech.thesisforge.guru`; display name is `ThesisForge` (all browser tab favicons, PWA/iOS icons, loading marks, and visible product titles must use the official black ThesisForge mark and `ThesisForge` brand name; never reintroduce retired legacy brand labels or green app logos).
- App Store packaging script is `scripts/build-ios-appstore.sh`.
- Non-App-Store direct file download center lives at `web/download/index.html`
  (`/download/`), serving `web/download/ThesisForge_iPhone_App.mobileconfig`
  (`Content-Type: application/x-apple-aspen-config` for 1-tap iPhone Safari
  Configuration Profile full-screen installation) and
  `web/download/ThesisForge_macOS_v1.0.dmg` (`Content-Type: application/x-apple-diskimage`
  universal macOS desktop wrapper).
- App Store submission requires a paid Apple Developer Program Team. A Personal
  Team can create development certificates, but cannot upload to TestFlight or
  the App Store.

## Required Vercel Production Env

The Vercel project `thesisforge` must have these production env vars:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- `VITE_AUTH_DEV_BYPASS=false`
- `VITE_AUTH_PROVIDER=supabase`
- Optional serverless proxy override: `AWS_API_ORIGIN`

The Supabase key is browser-publishable. Never use or expose a Supabase service-role key in the frontend.

## Build And Deploy

The standalone Ontology module and its earlier DBMF replacement are retired by
the user's explicit request on 2026-09-13. This supersedes earlier requirements
to ship Ontology. Do not restore either module's tab, screen, API, build
artifact, service start, snapshot export, or deployment dependency. Legacy page
links may return to the current application, never to the retired module.
Retired API paths must return 410/no-store before auth/body reads or forwarding;
Vercel and AWS share `server/retiredProductRoutes.js` as their route predicate.
Value Flow was also retired by the user's explicit request on 2026-09-22;
Discover now contains the independent AI Insights module. Legacy `valueflow`
page links redirect to `aiinsights`; `/api/investment/value-flow` returns 410.
The redesigned `/api/investment/*` workspace, AI Insights, strategies/CTA, and
`/api/valuation/*` remain active. Preserve historical snapshot databases and
dated research/brand artifacts; those archives do not require a live module.
Never promote a Vercel deployment built from a branch other than `trunk`.

For frontend changes:

1. Commit and push to GitHub `trunk`.
2. Deploy frontend through Vercel.
3. Verify `https://www.thesisforge.tech/` is served by Vercel.
4. Verify `https://www.thesisforge.tech/api/health` reaches AWS through the Vercel proxy.

For backend changes:

1. Deploy the Node/Express API to AWS Elastic Beanstalk.
2. Do not package Flutter `dist/` into AWS unless using the explicit emergency fallback:
   `INCLUDE_FRONTEND_DIST=1 bash scripts/package-aws-backend.sh`.

See `docs/deployment-contract.md` for the full runbook.

## Performance Regression Contract (2026-08-30)

- Measure backend changes with `npm run bench:api` against the same SQLite
  snapshot, runtime, sample count, and concurrency. Current schema-v3 artifacts
  cover active modules; archived v2 reports are not comparable to v3. Use at least 60
  samples and concurrency 20 for a release comparison; run both revisions three
  times and compare the median results.
- A performance optimization is complete only when at least one critical path
  improves p95 latency by 30% or more, no other measured critical path regresses
  by more than 5%, response semantic hashes remain unchanged, large JSON
  responses save at least 75% over identity transfer, and conditional requests
  return 304. Run `npm run check:performance` for the machine-readable gate.
- Run `npm run test:performance` for every transport, cache, payload-shaping,
  proxy, or static-cache change. This is additive to the normal server, Flutter,
  i18n, and production-build checks.
- The Vercel API proxy must preserve streaming, `Accept-Encoding`,
  `Content-Encoding`, `Content-Length`, `ETag`, and `If-None-Match`; do not
  re-buffer an upstream response or silently discard its compression metadata.
- Keep the Valuation landing request on `detail=summary&pricePoints=300`; fetch
  `detail=full&pricePoints=900` only after the user opens full research. A
  non-Guru initial route must not fetch `/api/gurus` until Guru is opened.
- Use immutable caching only for content-versioned URLs. When an immutable
  avatar or active static asset changes, update its URL version in the same release.
  Keep HTML and Flutter bootstrap/main/service-worker files on
  revalidation. Legacy service-worker cache cleanup must run once per migration,
  not on every visit.
- Store the reproducible benchmark inputs, before/after results, tests, and
  limitations under `docs/performance/YYYY-MM-DD/`. Do not claim production
  latency from a local benchmark, and do not deploy as part of an optimization
  audit unless the user explicitly requests deployment.
- Keep the public `/api/health` aggregate behind its bounded in-process cache
  and single in-flight verification. A health burst must not synchronously
  parse and audit every Guru curve once per caller or starve authentication and
  other API requests. Cache successes for no more than 30 seconds and failures for
  no more than five seconds; after expiry, a failed revalidation must replace
  the older healthy result rather than serving stale green status. Start the
  TTL only after the full audit completes so an upstream outage cannot drive a
  continuous full-curve audit loop. Production release verification must
  include at least eight concurrent health requests.

## 13F Update Contract

When the user asks to update 13F, guru holdings, Q2/Q3 data, new buys/sells, quarterly contribution, or position history, treat it as one atomic data-refresh job. Do not update only one cache.

### Definitions and completion vocabulary

- The **13F target set** is the explicit list of `manager13f` IDs selected for
  the filing refresh. An omitted target means the complete dynamic population,
  not a remembered count; expand the exact IDs in the audit report.
- **13F refresh success** means every enabled target has a current strict
  `ready` result and every disabled-simulation target is `unsupported`.
  **13F refresh degraded** is reserved for the one exact Peltz/JHG exception
  documented below. An older curve retained for UI continuity does not prove
  that the current filing refresh succeeded.
- The **required curve matrix** is
  `enabledManager13fGurus × requiredGuruCurveWindows`, currently the persisted
  5Y and 10Y windows derived from `server/gurus.js`. A **curve release pass** may
  contain only current strict `ready` rows or policy-permitted, exactly linked,
  audited `proxy_ready` rows. The strict 13F result and the displayable curve
  release result are separate assertions; never use a proxy to claim strict
  13F refresh success.
- 1Y and 3Y are derived trailing slices of the loaded 5Y curve, and the free
  date range is another client-side slice with rebased metrics. They are not
  separately persisted curves. `All` is an opt-in, fail-closed forensic
  calculation, not a required release row and not a substitute for 5Y or 10Y.

### Mandatory end-to-end 13F procedure

Use this sequence for every attempted 13F refresh. An "accepted 13F update"
means that a new or amended filing has passed source, parsing, identity, and
quality checks and is eligible to replace the current canonical quarter.

1. **Freeze scope and the before-state.** Derive the manager population from
   `server/gurus.js`; never use a copied manager count. Record the target
   quarter, UTC SEC cutoff, reason, job start, database path, affected manager
   IDs, current accession/report/filing dates, holdings count and reported
   value, dashboard/database generation, current 5Y/10Y curve identities,
   strict/proxy method versions, security-master hash, and public health result
   before changing data. Confirm no 13F, curve, or price writer is active.
2. **Verify the official filing.** Resolve every configured primary and
   `alternateCiks` filer, then verify form type, accession, report date,
   acceptance timestamp, source URL, source hash, amendment relationship, and
   the usable information table from the official SEC submission. A `13F-NT`,
   missing table, ambiguous amendment, mismatched CIK, or unsafe attachment is
   not an update: retain the prior usable quarter and record the failure.
3. **Build one canonical common-long book.** Convert reported 13F `$000` value
   units exactly once, aggregate duplicate CUSIPs before ranking, exclude
   explicit non-common claims, and reconcile the resulting holding count and
   total value back to the source table. Compute `new`, `increased`, `reduced`,
   and `sold_out` only against the prior comparable canonical filing. Summary
   counts must use the complete activity set even when the UI response is a
   balanced bounded sample.
4. **Resolve identities without guessing.** Update the SEC manifest and
   security master for every new identifier, issuer continuity, share class,
   reporting-entity transition, and corporate action. Exact CUSIP/effective-
   date evidence is required; fuzzy issuer matching, recycled ticker symbols,
   and unreviewed successor substitutions are release blockers. Quantify every
   unresolved selected-book weight.
5. **Refresh market-data dependencies.** Validate adjusted-close observations
   against the benchmark's expected sessions for every active holding interval,
   including truncated starts/ends and internal holes. Use only real,
   independently auditable observations. Never interpolate, forward-fill,
   manufacture a delisting price, or weaken a coverage gate to make a curve
   appear.
6. **Stage the complete dependent bundle.** Before a production write, create
   a recoverable, integrity-checked SQLite backup and a completed production
   EBS rollback snapshot; price repairs additionally require the controls
   below. Compute the guru snapshot, full dashboard merge, 40-quarter exposure
   history, full-detail 5Y strict/proxy artifacts, activity, and quarterly
   attribution without persistence. The snapshot and exposure must resolve to
   the same latest report date.
7. **Commit atomically or retain the last known good state.** Persist
   `guru_snapshots`, `dashboard_snapshots`, `guru_exposure_snapshots`, the
   strict backtest, and any permitted linked proxy through one
   `writeGuru13fRefreshBundle` transaction. Re-read and re-audit every stored
   surface after commit. A staging or transaction failure must leave the prior
   database unchanged. If post-commit read-back or integrity verification
   fails, restore the verified backup before reporting the job complete. Never
   leave a new header with an old curve or an old exposure with a new activity
   feed.
8. **Recompute the complete required curve matrix.** After any accepted 13F
   commit, sequentially refresh 5Y and 10Y for every enabled `manager13f`, not
   only the changed manager. Bind every row to one immutable root refresh
   generation, `not-before` time, strict/proxy method version, requested
   `method.years`, and exact security-master hash. The two windows are separate
   computations but one logical release: do not publish the aggregate status
   or success marker until both exact window result sets pass. The 1Y and 3Y
   controls are trailing selections of the current 5Y curve; `All` is a
   separate forensic request and is never required to manufacture a
   production-green result.
9. **Verify data, API, and UI together.** Check the detail header, filing lag,
   holdings, all four activity categories, 40-quarter position history, 5Y and
   10Y simulation, quarterly contribution, method/proxy disclosure, and the
   free date-range control in both languages. Test 1280x720 and 390x844. A JSON
   success without the corresponding visible product feature is incomplete.
10. **Run release gates and write an audit record.** Execute the required
    server, Flutter, build, i18n, performance, and targeted data-contract tests;
    deploy only from committed `trunk`; verify AWS, both Vercel aliases, public
    health, private-route denial, rollback material, and temporary-access
    cleanup. Write both machine-readable JSON and human-readable Markdown under
    `docs/audits/`, recording target IDs, affected filings, source hashes,
    before/after data, curve outcomes, failures, tests, versions, backup/rollback
    identity, and limitations without publishing licensed rows or secrets.

### Required update surfaces and invariants

- The 2026-09-03 catalog release adds Chris Hohn, David Tepper, Dan Loeb,
  Seth Klarman, Nelson Peltz, Andreas Halvorsen, David Einhorn, Mohnish
  Pabrai, and Pat Dorsey. The resulting catalog contains 38 profiles, 29
  `manager13f` profiles, and 28 enabled backtest managers; runtime health and
  release tooling must continue to derive these populations from
  `server/gurus.js` instead of freezing those counts in code.
- Renaissance Technologies is an enabled, explicitly labelled manager-level
  public-13F proxy, not a Medallion reconstruction. Its 5Y window must satisfy
  the strict 90% execution-coverage gate; an extended 10Y curve may use only a
  separately labelled, audited public-sleeve proxy that renormalizes only its
  fully priceable Top-60 holdings and never uses synthetic prices. The UI must
  disclose its included count, excluded weight, and that it is not a strict
  fund return. Keep Renaissance excluded from the concentrated-manager heatmap
  because its disclosed book is broad and systematic.
- Every configured profile must have exactly one matching
  `web/guru-avatars/<guru-id>.png` file. Avatar installation is fail-closed on
  a missing, extra, malformed, or non-144x144 PNG, and configured profiles must
  retain the canonical static URL fallback when the `guru_assets` table has not
  yet been populated. A frontend avatar change requires a cache-version bump.

- `guru_snapshots`: selected guru header, latest quarter, filing date, filing
  lag, reported 13F information-table value (not total fund AUM), canonical
  common-long value, options attribution, holdings count, latest holdings, and
  new buy/sell activity.
- `dashboard_snapshots`: guru list, overview cards, signal board, ticker heatmap, and cross-guru aggregates.
- `guru_exposure_snapshots`: 13F book history / position trajectory tab.
- `guru_backtests`: copy simulation and quarterly contribution.
- Market prices used by backtests must be current enough for the selected period; refresh latest prices first if the backtest end date is stale.
- If a manager changes or adds SEC reporting entities, add the new filer to `alternateCiks` in `server/gurus.js` and verify all 13F readers merge every CIK. Do not rely on the original `cik` only. Example: Bill Ackman/Pershing Square uses PSCM plus PERSHING SQUARE INC. after the reporting-entity transition.
- The product-default manager backtest is the trailing five-year audited window. Keep the 90% adjusted-close execution-coverage gate and leave missing weight in cash; never make a curve appear by lowering the gate or renormalizing only the covered subset. `years=all` remains an explicit forensic mode and must fail closed while legacy text 13F tables or point-in-time security histories are incomplete.
- Store the strict result and any public-sleeve proxy separately. `guru_backtests` is the strict audit slot; a proxy belongs only in `guru_backtest_proxies`, has its own method version, and can never satisfy a strict refresh or atomic strict-backtest gate. One exact, source-audited structural exception may let the surrounding snapshot/exposure bundle commit as `degraded`: Nelson Peltz's 2026 Q2 JHG holding became private before the filing was actionable. That bundle must atomically retain the linked strict `insufficient_data` and separately audited `proxy_ready` rows, must never report refresh `success`/`refreshed`, and must reject any other holder, quarter, CUSIP, failure code, synthetic price, or broken generation link. On public reads, a compatible strict `ready` curve always wins. A proxy may be shown only when strict is unavailable, every quarter retains at least 30% of the selected Top-60 common-long book and at least two fully priceable positions, and the UI identifies the included count, excluded weight, and largest exclusions. Preserve both reported-book and proxy-normalized weights. Never describe proxy performance as audited fund performance.
- Bind every persisted curve to its exact requested window in `method.years`; a 5Y payload may never satisfy a 10Y or All cache key. The daily scheduler must refresh 5Y and 10Y sequentially and publish one aggregate status that preserves failures from either window. Derive the required population from enabled `manager13f` entries in `server/gurus.js`; public health is green only when every enabled manager has a current displayable 5Y and 10Y strict or correctly linked proxy curve.
- Keep the simulation history controls available for every displayable strict or proxy curve: 1Y, 3Y, 5Y, 10Y, All, plus a freely draggable date-range bar. The curve and range bar must remain visible in the initial 1280x720 desktop viewport; place expanded methodology or proxy disclosure below the chart and keep 390x844 mobile layouts overflow-safe.
- Build each filing's Top-60 book only after aggregating duplicate CUSIPs and excluding explicitly non-common claims such as debt, preferred share classes, dated SPAC units, warrants, and rights. Use issuer wording only when it unambiguously describes a security class (for example preferred ADR/ADS or convertible preferred); never reject ordinary shares merely because a company name contains `PREF`, `PREFERRED`, `PF`, or `UNIT`.
- Treat issuer and CUSIP continuity as audited security-master data. In particular, Howard Hughes CUSIP `44267D107` continues 1:1 into `HHH`, Canadian Pacific CUSIPs `13645T100` and `13646K108` use ticker `CP`, and the approved Ackman-history mappings for United Technologies/RTX, Platform Specialty/ESI, Mondelez, Air Products, Valeant/BHC, and Nomad/NOMD must remain covered. Preserve the effective-date and corporate-action caveats in the mapping audit; do not describe UTX/RTX as an unconditional 1:1 alias or revert these rows to stale or unmapped symbols.
- Preserve Pabrai's point-in-time holding identity `N31738102 -> FCAU`, with the separately audited Sharadar price-symbol alias `STLA` for the provider's canonical series containing pre-2021 NYSE FCAU history, plus `384313508 -> EAF`. Repair the malformed `84670702 -> BRK.B` only for Pabrai's exact 2016 Q3 report, accession, issuer, and Class B row; never implement a generic left-pad repair for eight-character CUSIPs. The last selected FCA filing is 2020 Q1 and its modeled position exits before the January 2021 FCA/PSA combination, so do not add a synthetic merger leg to that holding interval or relabel the historical UI holding as STLA.
- Preserve a complete upstream `LAD` adjusted-close observation on 2022-05-17 for Andreas Halvorsen's active 5Y holding interval. If an offline candidate lacks that session, repair it only from an audited private source; never overwrite a complete production row merely to make two providers' rounded values identical. Without a valid observation the strict curve must fail closed with `missing_active_price`; do not hide the gap by downgrading the release contract, forward-filling 2022-05-16, or relabeling a proxy as strict. Licensed values and repair artifacts never belong in Git.
- Preserve the audited Bloomstran-history mappings `92556H206 -> PSKY`, `436106108 -> DINO`, and `780259206 -> SHEL`. Never map old Paramount/ViacomCBS CUSIP `92556H206` to the recycled `PARA` symbol. Alleghany `017175100` and PSTH `71531R109` ended in cash and must remain unmapped unless an action-aware cash-return model is explicitly audited.
- Preserve Soros's audited historical `489398107 -> KW` mapping and the same-issuer Overstock/Beyond/Bed Bath/Neighborhood continuity already represented by `690370101 -> NXH`. Kennedy-Wilson's 2026 cash acquisition does not continue into Fairfax stock. Do not replace Liberty Broadband `530307305` with LBRDA or Charter, legacy Caesars `127686103` with the current CZR, Altaba `021346101` with Alibaba, TiVo `88870P106` with Xperi, or Aetna `00817Y108` with CVS; those would substitute a different security or cash acquisition consideration.
- Build the distributable Guru security master only from the official SEC filing manifest plus exact OpenFIGI identifier results and public-provider validation; never generate it from application caches or a paid-vendor security master. Bind every manager13f strict and proxy cache row to both the current backtest method version and the exact security-master records hash. A different or missing security-master version is incompatible and must be recomputed; it may not retain or serve an older curve.
- A refresh is successful only when an enabled manager's backtest is `ready`; `insufficient_data` is a failed refresh, not a completed one. A manager with `disableSimulation: true` must return `unsupported`.
- An adjusted SQLite price subset is not proof that the requested history is covered. Refresh both a truncated database range and any internal hole against the benchmark's expected trading sessions from the upstream source, then let the active-holding engine decide whether a shorter IPO/delisting history or genuine trading halt is legitimate; never treat any non-empty adjusted subset as a full-range cache hit, skip an internal session, or forward-fill it.
- A production price repair must use exact independently verified provider rows through the internal audited repair route. Create a fresh EBS snapshot before the write, validate every OHLC/adjusted-close value, write the entire batch and its SHA-256 audit record in one transaction, and refresh the affected backtest. Never interpolate, forward-fill, lower coverage, commit licensed rows to Git, or expose provider/API credentials.
- Deliver a production Guru price-repair batch only from the private `guru-price-repairs/` S3 prefix. Bind it to the current root volume, a fresh completed source snapshot, an encrypted completed rollback copy, the exact release ID, method versions, security-master version, and explicit manager/window/status targets. The EB hook must call the installer and 5Y/10Y prewarm synchronously over loopback; create the `.done` marker only after current-generation health covers every enabled manager/window pair derived from `server/gurus.js`. Remove the temporary S3 object and its scoped read permission after verification.
- A backtest refresh that validates an audited price repair must run after any same-manager/window computation that began before the repair, then recompute once from the repaired generation. It must never join the pre-repair promise or race it with a concurrent writer that can overwrite the repaired result.
- Treat a shared trailing market-data cutoff as a bounded operational heuristic that reduces, but cannot eliminate, the risk of excusing a halt, delisting, or corporate action. It may move the effective backtest end only when the SPY series covers the requested market end and at least two active holdings share the exact same trailing cutoff, consistent with a common vendor lag, and only within seven calendar days. Persist the requested end, requested market end, effective end, lag, stale tickers, and every active ticker's latest date. A single stale security, mixed cutoff dates, internal price gap, or lag beyond the bound remains fail closed; investigate repeated or issuer-specific gaps rather than widening the heuristic.
- Keep serving and health freshness compatible with the accepted trailing-data policy: the curve end grace must be at least the seven-day trailing bound plus the five-day market-calendar buffer (12 calendar days by default). A fresh accepted curve must not become immediately stale because health uses a shorter window.

### Execution commands and trust boundary

- Local/CLI: `npm run refresh:13f -- --reason=manual-13f-update --years=5 --detail=compact --exposure-limit=40`
- Always pass `--years` explicitly to a CLI or protected refresh route. Never
  rely on a default window: a default may differ between the CLI and internal
  API, and an accidental `All` calculation cannot satisfy the release matrix.
- Limit a local refresh with `--guru=<comma-separated-guru-ids>` only when
  diagnosing or staging affected managers. Omit `--guru` for the complete
  manager population. The atomic updater persists full-detail audit artifacts
  even when the requested public detail is `compact`.
- After an accepted 13F commit, use `scripts/prewarm-guru-curves.mjs` over the
  loopback API with `--windows=5,10`, a unique immutable 64-hex
  `--refresh-generation`, an ISO `--not-before`, and the exact strict, proxy,
  and security-master versions. Write its report and success marker only to a
  private release path. This is the canonical production publication entry
  point; it runs 5Y then 10Y sequentially and enforces the full dynamic matrix.
  Do not hand-create a success marker.
- Before production publication, recompute the full matrix on an isolated
  database snapshot with
  `node scripts/audit-guru-curve-restoration.mjs --db <candidate.sqlite> --windows=5,10 --output <audit-path>`.
  The source database must remain byte-for-byte unchanged, and the generated
  JSON and Markdown reports must both pass.
- Production internal API calls must run inside the EB host over `http://127.0.0.1:${PORT}` with `Authorization: Bearer $INTERNAL_CRON_SECRET`. Both the Vercel proxy and EB nginx intentionally return 404 for every case-insensitive `/api/internal/*` path because the current EB origin hop is HTTP-only; never send internal bearer credentials through the public domains or the EB CNAME.
- Status checks follow the same loopback-only rule. Use the public `/api/health` endpoint for non-secret readiness verification.

### Verification after every 13F update

1. Check `/api/health` and confirm the expected database generation, curve
   generation, method versions, security-master hash, and dynamic population;
   an unrelated timestamp change is not proof of success.
2. Check `/api/gurus?refresh=1` or the relevant guru detail endpoint and
   confirm the expected accession, latest quarter, filing date, holdings count,
   reported value, and full activity summary were resolved together. A valid
   quarter with zero holdings changes is a valid result; do not require values
   to change merely to pass verification.
3. Check `/api/gurus/{id}/backtest?years=5&detail=compact` and
   `/api/gurus/{id}/backtest?years=10&detail=compact` for the product simulation
   and quarterly contribution. Check `years=all` separately only as a forensic
   coverage audit.
4. Check `/api/gurus/{id}/exposure?limit=40` for position history.
5. Verify the Vercel frontend at `https://www.thesisforge.tech` still talks to AWS through `/api/*` and does not hit the AWS frontend fallback.

If a manager has filed only `13F-NT` or a 13F without a usable information table, do not fabricate holdings. Keep the prior usable `13F-HR` quarter for holdings/backtest and surface the missing-information-table state in the refresh job errors.

### 13F data quality gate

An accepted 13F refresh is complete only when all of the following are true:

- The source accession, report date, acceptance timestamp, filer CIK(s), form,
  information-table attachment, URL, and content hash are present and mutually
  consistent. Amendment selection is deterministic and documented.
- Source row value, canonical common-long value, holding counts, duplicate
  aggregation, excluded non-common claims, and any unresolved identifiers are
  reconciled and recorded. The parser has not multiplied or divided the 13F
  `$000` unit more than once.
- `summary.reportDate`, exposure `latest.reportDate`, activity comparison
  quarter, backtest filing input, and dashboard latest quarter agree. Filing
  date and lag are visible rather than inferred from the report date.
- The dashboard still contains every configured profile; the affected manager
  has a non-empty canonical book or an explicit source failure; activity
  summary counts are computed from the full change set; and exposure contains
  up to the required 40 real quarters without fabricated empty quarters.
- SQLite `quick_check` and `integrity_check` return `ok`; the committed target
  set is exact; non-target table counts and semantic hashes are unchanged; and
  no transport-only cache field, fallback payload, or stale `dataStatus` is
  persisted as canonical data.
- The atomic job finishes as `success`, except the one exact documented
  Peltz/JHG structural case which must remain `degraded`. Any other
  `insufficient_data`, partial write, stale generation, or post-commit mismatch
  is a failed refresh and must preserve or restore the last known good bundle.
- A new manager is not complete until its catalog metadata, CIK evidence,
  snapshot, activity, exposure, 5Y/10Y outcomes, bilingual copy, and exact one
  valid 144x144 PNG avatar all pass their contracts.

### Guru curve refresh quality gate

In this section, "all curves" means the required 5Y/10Y simulation matrix for
every enabled `manager13f`. It is complete only when all of these gates pass:

- **Exact population:** the attested key set equals
  `enabledManager13fGurus × requiredGuruCurveWindows`; there are no missing,
  duplicate, disabled, or surprise manager/window rows. Health must derive the
  expected count dynamically and report `displayable == expectedRows` with an
  empty failures array.
- **Current identity:** each curve was generated after the release's
  `not-before`, carries the exact refresh generation, requested `method.years`,
  strict method version, and current security-master hash. A proxy also carries
  the exact proxy method/security-master versions and links to the current
  strict failure generation.
- **Strict quality:** status is `ready`; every rebalance meets at least 90%
  adjusted-close execution coverage; uncovered weight remains cash; weights
  reconcile to one; dates are sorted and unique; equity and benchmark values
  are finite and positive; active intervals have no unaudited price gaps; and
  headline return, security contribution, sector contribution, and industry
  contribution reconcile within the engine tolerance (`1e-10`).
- **Temporal integrity:** every filing becomes executable only on the first
  market session strictly after its public SEC acceptance time. Benchmark and
  holdings use the same total-return/adjusted-close basis and compatible market
  calendar. There is no look-ahead, pre-filing execution, future data, or
  silently stale end date. The bounded shared vendor-lag rule may move the end
  only under its exact documented conditions.
- **Proxy honesty:** a proxy is stored separately and may display only when the
  compatible strict result is unavailable, the manager/window policy permits
  it, every quarter retains at least 30% of the selected Top-60 book and at
  least two fully priceable positions, and the UI discloses included count,
  excluded weight, largest exclusions, and that this is not an audited full-
  fund return. Renaissance 5Y must be strict; a 5Y Renaissance proxy fails the
  release. No proxy may be described as Medallion or as the manager's complete
  performance.
- **Product completeness:** each displayable result supplies a usable equity
  curve, SPY comparison, quarterly contributions, method/data-quality detail,
  1Y/3Y/5Y/10Y/All controls, and the two-handle date-range bar. The initial
  desktop viewport keeps the curve and bar visible; mobile has no page-level
  horizontal overflow.
- **Production attestation:** the private prewarm report covers the exact full
  matrix and the public `/api/health` response reports the same identities and
  zero failures. The EB origin, `thesisforge.tech`, and
  `www.thesisforge.tech` must all agree. Burst-test at least eight concurrent
  health calls after the cache expires; all must return the same healthy curve
  matrix without health-audit timeout or request failure.

### Release stop conditions

Do not report a 13F or curve update as complete, do not create a success marker,
and do not promote a release if any required surface or quality gate above is
missing. Investigate the source, mapping, price, timing, or model error; keep the
last known good data visible; and report the exact failed manager/window and
reason. Never resolve a release blocker by lowering coverage, reusing an older
window under a new key, relabeling a proxy as strict, deleting the failed
manager from the expected population, or editing only the UI.

## Valuation PIT Data Contract

When valuation financials, management guidance, or historical fair values are refreshed, replace the valuation layer atomically. Do not mix legacy SEC/Trinity financial rows with the PIT dataset.

- US financials come from `jansen_us_firm_replication` Sharadar SF1 `ARQ` and `ART` records. Select the earliest `datekey` available for each fiscal period; exclude later restatements from historical point-in-time runs.
- Select financials independently for every fiscal period: prefer an `ARQ` row only when it contains core financials, otherwise use that period's valid `ART` row. Mark `ART` as trailing-twelve-month data so it is never multiplied by four or rolled into another TTM window. Do not use `MRQ`, `MRT`, or `MRY` dimensions for historical replay.
- BAE Systems (`BA.L`) and LSEG use official issuer releases. FY and H1 disclosures may be converted to TTM; Q1/Q3 trading updates may carry the latest already-disclosed TTM financial base and add only guidance visible on that event date. Record this construction and every source URL in `sourceRecord`.
- For UK issuer PDFs, normalize split thousands and decimals before parsing (`£9, 982m` means £9,982m; `£2. 2bn` means £2.2bn). Prefer exact table values over rounded headlines. When LSEG presents both pro-forma and statutory tables, use the statutory continuing-operations table for PIT financials and record that basis in `sourceRecord`; pro-forma acquisition comparatives are context, not reported history. Use operating/adjusted net debt from LSEG's management leverage framework before accounting total/net debt fallbacks, and record the selected debt basis. When an H1 release restates the prior H1 comparator, use that event-visible comparator in `current H1 + prior FY - prior H1`; do not reuse the older definition. Treat issuer-reported equity free cash flow as direct FCFE, not as CFO, and retain it when CFO/capex fields are unavailable. If an official issuer release and a transcript extraction provide the same guidance metric in one fiscal period, the official release is model-authoritative while the raw transcript evidence remains stored for audit.
- The dated LSEG current-valuation overlay (2026-08-28 assumptions, 2026-08-30 release) must keep three amounts distinct: issuer-reported consolidated Equity FCF, analyst-estimated parent-economic FCFE, and any FCFF/enterprise-value cash flow. The parent-economic FCFE DCF uses levered cost of equity, five explicit year-end cash flows, current ordinary shares excluding treasury, and no second deduction for net debt or Tradeweb/NCI. Its standalone DCF value must remain separately visible from the 40% DCF / 30% operating SOTP / 30% adjusted-EPS triangulation and the subsequent risk reserve. The analyst ownership adjustment, SOTP, and risk reserve must be labeled as estimates rather than issuer guidance. Never apply these 2026-08-28 assumptions retroactively to historical PIT rows, never use the 497m H1 weighted-average EPS denominator as the current-share DCF denominator, and never add buybacks or dividends again after valuing FCFE. A persisted valuation node dated after 2026-08-28 supersedes this overlay automatically; replace it only with a newly dated and audited model revision.
- Guidance must be management or issuer guidance observed on or before the model node date. Do not treat analyst questions, replay boilerplate, prior guidance comparisons, or historical actuals as new guidance.
- Every extracted guidance metric must identify its economic subject. Only `company_total` or defensibly `company_total_or_unspecified` periodic evidence may enter a company-level revenue, operating-income, or FCF input. Segment, acquisition, contribution, loss, delta, synergy, non-company and non-periodic amounts remain research evidence with a machine-readable exclusion reason.
- Treat every symbolic or textual plus-minus form (`+/-`, `±`, `plus or minus`, `+ or -`) as a center and uncertainty band, never as a two-endpoint range. For example, `$4.1 billion +/- $100 million` has a model amount of `$4.1 billion`, not `$2.1 billion`. Preserve the complete wording, and block release when a stored scaled monetary amount does not reconcile to the quoted center.
- Average two guidance amounts only when the source explicitly defines a range with `to`, `through`, a range dash, or `between ... and`. When only the last endpoint carries a scale, such as `$1.66-$1.68 billion`, propagate that same scale to both endpoints before computing the midpoint. Values connected by `versus`, `compared with`, ordinary `and`, capex-versus-FCF commentary, or separate metric clauses are independent observations, never range endpoints; select the amount nearest the owned metric and retain the other values only as evidence. Add a regression fixture whenever this rule changes.
- Legal range wording includes `range from X to Y`, repeated currency symbols (`$80 million to $84 million`), and the corresponding `between X and Y` forms. Reconstruct both endpoints before considering any later amount in the sentence; a subsequent share count, cost, NCI, tax or other metric must never replace the range endpoint. The release audit must test the original evidence independently of the extractor output.
- Compound clauses with multiple metrics and values require explicit owner binding. Ordinal pairing may use only metric owners that precede the first quoted amount, and the release verifier must independently reconstruct the pairings. A nearby cost, expense, saving, charge, synergy, tax or share-count amount owns itself and must never bind to revenue, operating income, EBITDA, EPS or FCF.
- Bind each monetary scalar to its explicit economic metric before selecting a model input. Treat all endpoints of one legal range as an atomic unit owned by the same metric; do not combine endpoints across clauses. For parallel lists such as `EBITDA and operating income of $2.6 billion and $1.9 billion`, preserve source order and bind each value once, including when `respectively` is omitted. The independent release audit must reconstruct these relationships from the original quote rather than trust the extractor's stored metric name or scalar.
- Preserve signs in directional ranges (`down $125 million to up $25 million` has a midpoint of `-$50 million`). In revision language such as `raise by X to Y`, the revised model target is `Y`; `X` is the change amount and remains evidence only. An amount immediately before its owner (`$11 billion of operating cash flow`) belongs to that following metric.
- A four-digit fiscal/calendar year is a date token, never the left endpoint of a shared-scale monetary range. In wording such as `fiscal year 2025 to $1.4 billion`, the year must not inherit `billion`; share repurchases and other capital-allocation amounts own their quoted values and cannot become FCF guidance merely because FCF appears later in the sentence.
- Official SEC and UK importers must use the same audited monetary/range parser and subject-owner rules as transcript extraction. Do not maintain a looser second parser for filings. Historical actuals, prior-guide comparisons and non-guidance amounts remain research evidence regardless of source type.
- Named-month quarter wording such as `March quarter`, `June quarter`, `September quarter`, and `December quarter` is quarterly scope. Do not annualize or treat such guidance as an unscoped annual amount.
- An explicit quarter target such as `Q2 FY2027` is quarterly guidance even though it also contains a fiscal-year token. Quarter scope outranks the year token. Statements that a company `met`, `exceeded`, or `was within` prior guidance describe historical performance and cannot create a new forward model input.
- Preserve guidance scope. Prefer explicit full-year guidance; never use a quarterly or unscoped amount as full-year revenue, operating income, or free cash flow. When only quarterly revenue guidance is available, annualize it, bound it against PIT trailing revenue, blend it with the formula forward estimate, and record the raw amount, annualized amount, bounded amount, blend weight, and inferred/explicit scope in the model inputs. Ambiguous annual-scale amounts remain research evidence and do not replace formula/TTM model inputs.
- An annual value and a cumulative multi-year target are different economic inputs. Never average them, annualize the cumulative target, or let a medium-term section heading re-label an annual bullet. Store the cumulative target as research evidence unless the model has a separately audited multi-year route.
- Storing guidance is not enough: every applicable operating, growth, or revenue-stage model node must either consume plausible explicit annual guidance or record the reported amount and a machine-readable rejection reason. The strict release verifier must fail when scoped revenue, operating-income, or free-cash-flow guidance is silently ignored. Financial/customer-cash routes may exclude non-applicable guidance only through their disclosed economic model route.
- Normalize reported growth continuously with only information visible at that node: winsorize finite source observations, take the configured rolling median (eight reporting periods by default), and then apply the valuation-profile cap. Never discard a valid triple-digit growth observation and fall back to a default merely because it crossed an arbitrary threshold. Transcript-reported actual growth is research-only. Only a clear management guidance growth metric may enter the model, at no more than 25% weight and bounded to within 15 percentage points of the PIT financial trend; store the raw guidance, bounded guidance, financial trend, window, sample count, and applied weight in every model node.
- Rebuild guidance in this order: management transcripts, official UK issuer releases, official SEC issuer filings, then ECB FX reference rates. Each importer may delete only rows owned by its own `source_type`; a transcript refresh must never delete official issuer guidance.
- A reported fiscal year and the forward guidance target year are separate fields. In particular, a Q4/FY release may report FY2025 results while guiding FY2026. Derive the target year from the nearest preceding annual-guidance heading, stop at the next medium-term or later-year heading, retain both years, and regression-test every year-end rollover used by the model.
- Preserve guidance in its reported currency. When it differs from the valuation financial currency, convert only the model input with the ECB reference rate visible on the guidance date (or nearest prior rate), and retain source amount, source currency, conversion rate, rate date, and ECB URL in the model input. Never add unlike currencies directly.
- Apply the same official-rate contract to financial statements. A cross-listed/ADR price ratio is not FX and must never convert financials; fixed currency fallbacks are forbidden. Store the paid source currency, target model currency, ECB rate pair/date/value/URL, conversion formula, and raw provider FX field at every converted PIT row, and fail closed when the event-visible official rate is unavailable.
- If official filings have been reviewed but contain no quantified group-level guidance, record `no_quantified_official_guidance`; do not manufacture a value. Private companies without public quarterly guidance remain explicitly uncovered.
- Missing values remain `null`. Never use zero, market price, a later filing, or a future share count to fill a historical financial input. A carried prior disclosed value must be explicitly recorded in `sourceRecord.metricDerivation`.
- Preserve Transcript/Q&A, users, portfolios, Guru, archived Ontology, prices, dividends, and podcast data. A production valuation refresh may replace only `valuation_pit_source_metadata`, `valuation_pit_financials`, `valuation_pit_guidance`, `valuation_pit_model_runs`, `valuation_pit_price_observations`, `valuation_ticker_snapshots`, and `valuation_snapshots`. These seven tables form the atomic valuation artifact; the separate Guru `price_points` table is not part of that replacement.
- Before replacing valuation snapshots, carry forward stored transcript Q&A and its bilingual fields only when the normalized fiscal period matches exactly; never carry guidance or model inputs from the prior snapshot. First rebuild English coverage with `TRANSCRIPT_QA_TRANSLATE_ZH=false`. Then generate and audit the local Qwen cache, and attach Chinese only with `TRANSCRIPT_QA_TRANSLATE_ZH=true`, a fixed `TRANSCRIPT_QA_GENERATED_AT`, and a persistent `TRANSCRIPT_QA_TRANSLATION_CACHE_PATH`. Translation is opt-in and cache-only; a missing cache item must fail the run instead of calling an online translator. Every modeled history row must have an explicit Q&A coverage status, every `has_qa` row must contain complete stored English and Chinese Q&A, and transcript research must be marked `includedInValuationInputs: false` so it cannot alter historical fair value.
- Transcript Q&A extraction must begin strictly after a detected Q&A boundary. Reject prepared-remarks questions, audio checks, procedural handoffs, name-only fragments, and answers without substantive management context. Rebuild Chinese fields with `scripts/translate-valuation-qa-mlx.py`; its deterministic number protection and audit sidecar must pass before enrichment, and the strict verifier must show every attached Q&A row is bilingual.
- Back up the AWS runtime database before the transaction. Abort and roll back if any required ticker is blocked, SQLite integrity fails, guidance is dated after its model node, or non-valuation table counts change.
- Run the valuation import twice on a release-database copy with the same validated fixed `PIT_VALUATION_GENERATED_AT`. Confirm ticker counts, model-run counts, focus ticker fair values, CIK-dependent supplements, model signatures, and snapshot signatures are identical before deploying; wall-clock timestamps must not make an otherwise deterministic release differ.
- Build current US index coverage from the official SPY holdings workbook and the paid Sharadar S&P 500 snapshot. Deduplicate issuers by normalized SEC CIK, retain alternate listed share classes as aliases, and choose the largest official SPY weight as the canonical share class. The release manifest must contain exactly 503 securities and 500 unique issuer CIKs.
- Keep existing non-index research tickers in Valuation unless the user explicitly retires them. A current S&P refresh is a union with tracked extras, not a destructive replacement of the research universe.
- Paid split-adjusted price rows must be strictly positive. Reject zero or negative closes when seeding, refreshing, selecting a historical price, and writing compact valuation snapshots. Every current S&P issuer and every retained tracked ticker must have a positive latest price and at least one positive stored price point before release.
- Treat `price_points` and paid split-adjusted ticker-snapshot OHLC values as already normalized to the quoted security currency. Map valuation aliases such as AZN and LSEG to `AZN.L` and `LSEG.L`, but never infer pence conversion from a `.L` suffix or divide a stored price again. The release verifier must reconcile every non-null model-node comparison price to the exact dated close in either raw `price_points` or the released paid ticker snapshot; a price absent from both sources is a release blocker.
- Every modeled historical node must retain both the selected fiscal-period source record and its ART trailing-twelve-month source record when available. Audit the filing/availability date for the base record, TTM record, every metric-level lineage record, guidance evidence, and FX conversion; none may occur after the model node.
- A single loss-making observed period may not supply the below-operating burden for normalized earnings. Use an observed burden only when both operating and net margins are positive. Only an explicitly cycle-normalized economic profile may fall back to its modeled operating margin and tax rate; other loss-making profiles require positive independent evidence or remain unmodeled.
- Apply valuation methods by economic profile. Banks, insurers, capital-markets firms, asset managers, and insurance brokers must not use customer cash flow in an operating-company DCF. Cyclical companies use through-cycle margins/earnings and a recorded FCF sustainability cap. Every DCF must satisfy the release bounds for WACC, terminal growth, WACC-minus-growth spread, and terminal-value share.
- Treat managed-care issuers and payment processors as customer/policyholder-cash businesses. They use point-in-time current/cycle EPS and must emit the customer-cash-flow exclusion; they must not use customer, settlement, or policyholder cash in FCFE DCF. Do not map PayPal, Fiserv, Global Payments, Corpay, FIS, or Block to either a generic software DCF or the Visa/Mastercard card-network profile.
- Use an issuer's economic profile, not only its broad sector label. CIEN and COHR use the optical-networking turnaround family; CPAY, FI/FISV, FIS, GPN, PYPL, and XYZ use the payment-processor family. Keep ticker-specific exceptions and the S&P universe manifest aligned.
- Base fair value must not contain a blanket platform, autonomy, space, or other optionality multiplier. Store an explicit optionality multiplier only as a separately labeled bull-case scenario input. Base-case hard ceilings are 40x EV/sales, 72x target P/E, and 65% normalized operating margin unless the release contract is deliberately revised with tests and an audit note.
- Reject an EV/sales component when net debt cancels at least 99% of its enterprise value. A tiny positive residual is false precision, not a defensible equity fair value; leave the PIT period explicitly unmodeled when no independent method remains.
- Use period-end quoted-security shares for per-share valuation: `sharesbas` first, then `shareswadil`, then `shareswa`, multiplied exactly once by the recorded applicable security factor. Never infer a split from a change in reported shares or retroactively rescale prior fair values. DGE.L is a London ordinary share and therefore records but does not apply the DEO ADR factor.
- A source fiscal period may be absent from model runs only when it is explicitly classified as non-modelable with an auditable reason. Never silently skip a period because earnings or FCF are negative.
- Run the strict release verifier before production: `node server/verifyPitValuationRelease.js <baseline.sqlite> <run1.sqlite> <run2.sqlite>`. It must report `status: pass`, identical model and snapshot signatures across both runs, zero unexplained temporal jumps, zero unexpected modelable gaps, zero source-date failures, zero non-positive stored prices, and unchanged non-valuation table counts.
- Generate the persistent all-ticker audit ledger with `SQLITE_DB_PATH=<candidate.sqlite> npm run audit:valuation:ledger`. Commit `server/reports/valuation-audit-ledger.json` and `.md`; production is blocked while the ledger contains any unresolved P0/P1 finding. Price/fair-value divergence is a watch item, never a reason to feed market price into fair value.
- Build the production artifact from one audited candidate with `python3 scripts/build-pit-migration-artifact.py --database <run1.sqlite> --release-audit <release-audit.json> --output <valuation-pit-migration.sqlite.gz>`. The generated manifest owns the artifact SHA-256, model version, strict-audit signatures, and expected table counts; never hand-edit those release values into the deployment hook.
- Deploy only a strict-audit candidate. Record the pre-deploy Elastic Beanstalk version, create a fresh compressed database backup and EBS snapshot, stage the seven valuation tables, replace them in one `BEGIN IMMEDIATE` transaction, and retain the prior version and backup for rollback. Re-run health, coverage, valuation, Portfolio, Guru, and Transcript checks against production before declaring the update complete.

### Guru-to-Valuation coverage expansion (2026-09-05)

- Guru identity coverage is not valuation coverage. Reconcile exact securities
  appearing in the requested Guru holdings against released valuation ticker
  snapshots/explicit aliases and report the denominator. The public SEC/security
  master is a historical top-60 selected-book manifest; never call that a full
  live-Guru audit. Funds, private companies and unresolved identities require
  separate dispositions, not a generic operating-company DCF.
- Keep reviewed Guru additions in `server/config/guru-valuation-universe.json`,
  separate from the 503-security/500-issuer S&P contract. Unreviewed entries are
  research queues, not model authorization. Check CIK/CUSIP/share class, source
  ticker, quoted-security factor, reporting/model currency, economic profile and
  dated identity evidence before activation. Preserve existing valuation tickers
  and use the same additive union in source construction and release checks.
- Use `scripts/audit-guru-valuation-coverage.py` for a read-only local inventory
  and `scripts/stage-guru-valuation-expansion.py` for new private input candidates.
  Staging is not completion: candidate `pit_issuer_review` rows must all be
  `reviewed` before model application. Every modeled issuer needs a guidance
  coverage row. `--allow-incomplete` is dry-run only and must never accompany
  `--apply`.
- Review official management releases even when transcript evidence exists.
  Bound each research batch by exact tickers and an as-of cutoff. Missing
  guidance may be recorded only after a successful review; an unretrieved or
  failed filing is not proof of no guidance. Bare currency symbols require dated
  issuer reporting-currency evidence; unknown currency or unavailable official FX
  must prevent monetary model consumption, including raw-amount fallback.
- For IFRS retailers, reconcile financing-classified lease principal, lease
  interest and other interest before using CFO minus capex as equity cash flow.
  Check intangible capex and supplier-finance classification; never deduct the
  same supplier payment twice. Preserve reported CFO separately from economic
  adjustments. Handle outstanding share classes, unvested awards and options in
  an explicit claims schedule; do not both expense an existing award and charge
  its dilution, or use a market-price-dependent illustrative diluted count as a
  fixed model input. A completed cash-flow bridge is not a completed valuation.
- A source-only audit or an unapproved scenario calculation cannot satisfy the
  valuation release gate. Record staged, modeled, independently audited, and
  deployed counts separately. `scripts/report-guru-valuation-readiness.py` and
  `scripts/audit-staged-guru-guidance.mjs` report input-stage progress only;
  neither authorizes publishing a price. Keep failed issuer-file access and
  unresolved monetary currency separate from a genuine absence of guidance.
- When importing an isolated local transcript batch, merge only the explicit
  ticker scope and transcript-owned events with their original dates. Preserve
  all official evidence, unrelated coverage rows, and issuer-review states;
  re-run the scoped official review afterward. Never copy a freshly rebuilt
  transcript coverage table over the full candidate universe.
- Source counts must distinguish extraction occurrences from unique persisted
  events. Identical event IDs are idempotent only when the complete payload and
  typed fields agree. A conflicting payload or source owner must roll back the
  transaction; never silently overwrite it with `INSERT OR REPLACE`.
- A comparison price needs an exact provider, field, quoted-security currency
  and adjustment basis. Sharadar `close` is split-only; Yahoo `close` is a
  separate provider series. Do not compare them as identical observations or
  overwrite a paid historical point merely because `price_points` was read
  last. Reconcile PIT price evidence to the exact ticker, fiscal period and
  model version. Same-series conflicts remain blockers at the original strict
  tolerance. Never change Guru backtest prices during a valuation-only repair.
- When old normalized financials lack reporting currency, do not infer it from
  USD quote currency or `fxusd=1`. A dated SEC statement-unit ledger must match
  the independently verified CIK and original cached filing facts. Multiple
  currencies, future evidence, missing identity or stale evidence remain
  unresolved. Append the audited reporting-currency evidence only in a new
  candidate copy; preserve original amounts, source records, FX and dates.
- A current-only economic scenario is not authorization to generate generic
  historical DCFs. Preserve its reviewed date, cash-flow/claims bridge and
  explicit method; an EV/sales scenario must never be labeled DCF. Source-only
  passes, isolated model diagnostics and two identical partial-batch signatures
  do not replace the complete additive release gate.

## Guru Terminal Visual Baseline (2026-09-02)

- Preserve the compact three-column Guru research terminal established by the
  2026-08-31 Bill Ackman reference screen: universe rail, research workspace,
  and signal/market-lens rail remain visible together at desktop widths.
- Keep the desktop brand subtitle as `Guru Stock Analysis`, the functional
  `Gurus / Firms` universe switch, the compact five-metric manager header, the
  `New Buys & Sells` module label, and the `1Y / 3Y / 5Y / 10Y / All` chart
  controls. Keep 5Y as the fast audited default; load 10Y or All only when the
  user requests it, retain the last ready curve if a longer forensic window
  fails closed, and never relabel a 5Y payload as full history. Do not replace
  this shell with a taller audit-card layout unless the user explicitly requests
  a redesign.
- The compact header must remain economically accurate: `Reported 13F value`
  is the reported information-table market value, not total fund AUM. Keep
  common-long and option attribution available in research detail even when the
  compact header does not show separate cards.
- Retain the quarterly Market Lens, Renaissance coverage, audited five-year
  default backtest, force-refresh path, truth-state status, and bilingual error
  handling behind the restored visual shell. A visual restoration must never
  roll back those data or safety features.
- Keep both the two-handle range control and the Guru simulation curve visible
  in the 1280x720 first viewport. Use the 48px inline desktop range bar before a
  compact 120px curve at short viewport heights, while allowing a taller curve
  on taller screens. The range must rebase the selected curve and recompute its
  metrics; loading 10Y/All must not change the 90% execution-coverage gate.
- Treat 10Y and All as extended-history windows. Public reads may return only a
  current-method SQLite result (fresh or explicitly stale); a stale 10Y result
  may revalidate in the background, but a stale All result must not schedule
  work. For either window,
  a cache miss must fail closed without starting a synchronous computation.
  Pre-warm the exact 10Y method version through the protected internal refresh
  route before exposing or promoting a frontend that offers the 10Y control.
  All remains forensic and may be computed only by a protected refresh while
  legacy corporate-action coverage is being completed.
- Every deck page with a bounded height must scroll its rows rather than use an
  overflowing `Column`. Verify the Guru page at 1280x720 and 390x844 with zero
  Flutter render overflows before release.

## Bilingual UI Contract

Chinese and English are release-critical product modes, not best-effort labels.

- Route all Flutter UI copy through `context.tr`, `context.ui`, or the shared localization helpers. Do not add visible hard-coded copy outside those layers.
- Translate API-supplied statuses, sectors, industries, strategy names, model labels, error messages, and dynamic sentence templates in both directions. Do not assume a backend value is already presentation-ready.
- English mode must contain zero CJK UI copy. Chinese mode must contain zero untranslated interface copy; official company names, tickers, brands, source titles, and standard financial acronyms are the only allowed exceptions.
- Include navigation, filters, buttons, charts, tables, dialogs, tooltips, placeholders, loading, empty, disabled, warning, and error states in every language review.
- Preserve language across active application navigation and URL state, including retired-page redirects. The compact mobile header must always expose a language switch without requiring horizontal scrolling.
- Before publishing a UI change, run `npm run audit:i18n`, `flutter analyze`, `flutter test`, and `npm run build`. Verify both languages on desktop and a 390x844 mobile viewport, including dynamically opened panels and dialogs.
- Keep the current release ledger in `docs/audits/bilingual-coverage-2026-08-30.md` and update it whenever a new user-facing surface is added.

### Public research entry (2026-09-05)

- First-time terminal visitors default to English; preserve an explicit
  `lang=zh` across active routes and legacy redirects. Do not encode
  Chinese by deleting `lang` now that omission means English.
- `/research/isrg/` is an intentionally English-only, unauthenticated public
  case requested by the user. It is not a replacement for the bilingual
  authenticated terminal and must never require private API credentials.
- Keep this page a dated, reviewed snapshot. Distinguish model availability,
  fiscal period, market-price observation, and publication dates. No “live” or
  “today” labels without a newly audited update.
- Preserve the blended valuation/standalone DCF distinction, three assumptions,
  numerical change explanation, countercase and retrospective-PIT caveat.
  Charts must use real model nodes and dated prices; do not smooth or invent
  observations. Publish only the allowlisted curated snapshot, never raw
  provider statements, credentials, user or portfolio data.
- Regenerate with `npm run build:research`; run `npm run test:research` and the
  normal language/build gates. Re-capture the social preview when visible data
  or copy changes. The build fails if generated HTML drifts from the snapshot.
- The terminal CTA must retain `view=valuation`, `valuation=ISRG`, `lang=en`.
  Do not advertise saving to an account before a real persistence flow exists.

## Social Creative Data Contract

- Keep the current ThesisForge social brand pack under
  `docs/brand/2026-08-30/`. New assets in this release family must retain the
  August 30, 2026 release date while separately displaying the true underlying
  data cut; never relabel stale market or strategy data as August 30.
- The canonical NVDA Q2 valuation asset is
  `nvda-q2-valuation-card-windowed-en-1600x900.png`, generated by
  `scripts/export-nvda-q2-valuation-social.mjs` from the audited v55 NVDA PIT
  snapshot and the preserved native curve crop
  `nvda-q2-valuation-curve-windowed-source.png`. Its chart viewport begins at
  the first valid fair-value node rather than the earlier price-only history;
  the source database history remains intact. Its release date is 2026-08-30,
  its valuation node is 2026-08-26, and its latest market-price observation is
  2026-08-27. Preserve the native curve, axes, dates, and legend; never redraw,
  smooth, or manually reshape it. The $274.86 headline is a 36% EV/sales / 32%
  normalized-earnings / 32% FCFE-DCF blended fair value, not a standalone DCF.
  Keep reported TTM FCF ($127.0bn) distinct from forward model FCF ($182.2bn),
  and label the $108bn Q3 revenue amount as management guidance with a ±2%
  range. At the $227.98 price cut the modeled gap is 20.6%, so use
  `Undervalued` or `model gap`, never `very cheap`, `deep value`, or a
  guaranteed-return claim. The NVIDIA mark must come only from the official
  NVIDIA Newsroom asset preserved at
  `assets/branding/external/nvidia-logo-horiz-wht-16x9-official.png`; keep its
  artwork, proportions, colors, and clear space unchanged and visually separate
  it from ThesisForge branding. Always include the NVIDIA trademark notice plus
  an independent-research/no-affiliation-or-endorsement disclosure.
- Strategy graphics must render exact reproducible observations. Do not invent,
  smooth, or manually reshape an equity curve. Preserve the source series,
  methodology, validation status, caveats, and provenance beside the exported
  image.
- The canonical Ontology social asset is
  `ontology-soft-overlay-6m-en-1600x900.png`, generated by
  `scripts/export-ontology-strategy-social.mjs` from the full 2,165-point
  `ontology-soft-overlay-6m-equity-daily.json` series. Its release date is
  2026-08-30 and its latest reproducible strategy data is 2026-08-13.
- The canonical PLTR evidence asset is
  `pltr-ontology-case-study-en-1600x900.png`, generated by
  `scripts/export-pltr-ontology-case-study.mjs` from
  `pltr-ontology-case-study-data.json`. Its release date is 2026-08-30, its
  filing data cut is 2026-08-04, and its verified post-filing heat snapshot is
  2026-08-05. The graphic is a Q2 confirmation story, not a post-Q2 rank-jump
  story.
- Describe the PLTR case study as an August 2026 point-in-time diagnostic
  replay, never as proof that a live alert was archived or delivered. On the
  historical AI value-chain financial-change ranking, PLTR was already #2/74
  with heat 85.2 on 2026-07-31 and remained #2/74 with heat 85.7 on the
  2026-08-04 filing date (85.9 on the next trading day). Say Q2 confirmed an
  existing lead; do not say the latest Q2 caused the ranking to explode.
- `Heat rank` is the descending `heat_score` order on the historical ranking
  tab over 74 graph companies with a report period and normal signal state.
  It is separate from V2 decision-snapshot `ontology_score` ordering,
  strategy/book ranks, valuation, and price performance. In particular, the
  V2 decision ordering moved from #18/146 at 1.318 on 2026-07-31 to #32/177 at
  1.166 on 2026-08-13; never mix that series into the heat-rank chart.
- The actual historical heat-rank breakout occurred after 2025 Q3: #6/74 on
  2025-10-31, #3 on 2025-11-04, #2 on 2025-11-05, and #1 on 2025-11-14.
  PLTR remained #1 on 2026-02-17 and had been #2 since 2026-03-19 before the
  latest Q2 filing. Keep this history distinct from the V2 sequence: first
  green flag on 2025-08-06, reset to watch on 2025-11-05, peer-context rebuild
  on 2026-02-18, and fixed-rule Top-20 replay entry on 2026-05-08.
- The canonical PLTR product screenshot is
  `pltr-ontology-graph-screenshot-en-1600x900.png`, generated by
  `scripts/export-pltr-ontology-graph-screenshot.mjs` from the preserved
  `pltr-ontology-graph-source.png`. Package the screenshot only outside its
  rounded frame: do not regenerate, relabel, retouch, or crop away the selected
  PLTR node, the right-side PLTR detail panel, or the visible data cut. Keep the
  official ThesisForge mark deterministic and add no Palantir logo or implied
  endorsement.
- In PLTR materials, `peer context` means the Ontology V2 broad-stage composite
  score. It is not peer-stock performance, measured customer contracts, or
  revenue, and it must not be conflated with the V4 soft overlay's separate
  `peer_confirmed` field. The latest V2 peer-context score stayed elevated but
  declined quarter over quarter; do not say it exploded in the latest quarter.
- Treat “Palantir is becoming mission-critical software for the AI era” as a
  ThesisForge research interpretation, not a model output or established fact.
  Use the Palantir name and PLTR ticker only for editorial identification; do
  not use Palantir logos, interface captures, trade dress, or imply affiliation
  or endorsement. Keep the independent-research and no-affiliation disclosure.
- Competition and mission-criticality claims in PLTR social copy must be tied to
  primary evidence: official customer deployment demonstrations plus public
  procurement, evaluation, justification, or award records. Treat
  Palantir-produced customer videos as issuer/customer claims and government
  award records as procurement facts. Do not say every case or tender was
  reviewed unless a complete source ledger exists, and keep “mission-critical”
  explicitly framed as the ThesisForge conclusion.
- Describe the 2018–2026 Ontology result as a diagnostic research evaluation,
  not a live result or fresh blind test. Always disclose the −42.5% historical
  maximum drawdown, high turnover, modeled-cost basis, and that the V4 overlay's
  incremental bootstrap 95% confidence interval versus V2 crosses zero.
- Keep the ThesisForge mark, dark navy shell, mint strategy line, amber benchmark,
  red risk treatment, and `thesisforge.tech` lockup deterministic. Generated
  imagery may be used only as a low-contrast atmospheric background, never for
  exact copy, logos, portfolio holdings, or quantitative charts.
- The canonical Gavin Baker sector-edge asset is
  `gavin-baker-sector-edge-en-1600x900.png`, generated by
  `scripts/export-gavin-baker-sector-edge-social.mjs` from the public-filing
  production backtest, official Atreides SEC 13F reported-share history, and
  the frozen Sharadar SF1 taxonomy. Its release date is 2026-08-30. The card
  covers 26 completed filing-to-filing windows from 2020-02-14 through
  2026-08-14 and 634 priced common-stock observations; exclude the current
  incomplete 2026 Q2 window. `Win` means beating SPY over the identical public
  filing-execution window, and `payoff` means average positive excess return
  divided by the absolute average negative excess return. `High-conviction
  add` means a new common-stock position or at least a 50% quarter-over-quarter
  increase in reported shares ending at 10% or more of the priced disclosed
  long book. The displayed 48% / 1.52x overall big-add result and 63% / 3.33x
  semiconductor big-add result are delayed 13F proxies; the semiconductor
  subset has only eight observations. Never present them as Gavin Baker's
  personal trades or Atreides fund performance, and retain the disclosure that
  13F omits shorts, cash, private assets, derivatives, and intra-quarter trades.
- The canonical 10-second ThesisForge product promo is
  `thesisforge-system-promo-en-10s-1920x1080.mp4`, generated by
  `scripts/export-thesisforge-system-promo-video.mjs`. Its release date is
  2026-08-30 and its preserved product recording was captured on 2026-08-14.
  Keep the source Market Ontology UI recognizable: cropping, scaling,
  color-balancing, framing, and deterministic motion overlays are allowed, but
  never redraw, relabel, or fabricate the recorded product state. Preserve the
  10.0-second duration, 1920x1080 16:9 canvas, 30 fps H.264/AAC delivery,
  ThesisForge mark, `thesisforge.tech` CTA, and exact copy recorded in the
  companion manifest. The `500+ companies` statement is a coverage claim, not
  a performance claim. Keep `Research only · not investment advice` visible.

## Production Memory, Portfolio & Guru Leaderboard Contract (2026-11-17)

- **Commit-Before-Deploy (No Ephemeral Releases):** Never deploy uncommitted
  working-tree patches via temporary `GIT_INDEX_FILE` or ad-hoc archives. Every
  verified backend or frontend change MUST be committed onto local `trunk` and
  pushed to `origin/trunk` on GitHub so subsequent strategy or feature commits
  never silently overwrite prior production fixes.
- **Production `t3.small` Memory & Latency Guardrails:**
  - Retain `.platform/hooks/predeploy/01_create_data_dir.sh` (2 GiB `/var/swapfile`
    provisioning and `/var/app/data/user-portfolios` `webapp:webapp` `0700`
    ownership). Whenever running SSM commands on the Elastic Beanstalk host,
    never leave root-owned files inside `/var/app/data/user-portfolios`.
  - Retain the `< 3.5 GiB` total-RAM guards in both
    `server/breakoutPullbackStrategy.js` and `server/qqqSchdRotationStrategy.js`
    so Python strategy artifact rebuilds never spawn in-process on `t3.small`.
  - Retain `server/heavyWorkerLimiter.js`, `lazy_views=True` and bounded DuckDB
    memory limits in `fact_os/repository.py` and `fact_os/rpc.py`,
    `PRAGMA data_version` read caches in `server/investmentSource.js`,
    single-date price caching in `server/portfolioRisk.js`, expired-JWT `401`
    handling in `lib/main.dart`, and HTTPS keep-alive in `api/proxy.js`.
- **Multi-Account IBKR Aggregation & Confirmed Passive Income (`Portfolio`):**
  - Keep cross-account same-security aggregation in `server/investmentPortfolio.js`
    and IBKR Flex `Error 1018` rate-limit backoff retries in
    `server/portfolioClient.js` (`loadIbkrFlexXml`).
  - Confirmed passive income (`server/portfolioIncome.js`,
    `lib/investment_portfolio_passive_income.dart`) includes strictly settled
    cash dividends (`netCash` after withholding tax) plus IBKR `BookTrade` OTM
    expired short Calls (`putCall === 'C'`, `buySell === 'BUY'`,
    `tradePrice === 0`, `tradeDate === expiry`, `fifoPnlRealized > 0`). Open,
    manually bought-to-close, or ITM-assigned short calls remain isolated from
    confirmed passive income.
  - Keep Expired Short Calls (`#F5A623` warm amber-gold) and Cash Dividends
    (`#20C997` emerald-jade; `#38BDF8` in color-blind mode) visually distinct
    even in Black Edition (`blackEditionPreview`, where `palette.accent` is
    blue), retain encrypted multi-year passive ledger accumulation in
    `portfolio_passive_ledgers` (`server/userPortfolioStore.js`), and preserve
    the annual passive income dropdown (`passive-year-dropdown`) plus strict
    same-period YoY comparison (`passive-yoy-card`). Keep `My holdings`
    (`lib/investment_portfolio_home.dart`) in its clean single-row table layout
    without inline multi-line Guru clutter.
- **Discover -> Guru Rankings & Partial-Quarter Scope (`GuruHoldingsMatrix`):**
  - `GuruHoldingsMatrix` (`lib/investment_guru_holdings.dart`) must default to
    `allGurusScope = true` (all reporting Gurus) rather than a hardcoded subset
    of four managers, preventing empty screens during partial 13F filing-season
    quarters (e.g., 12/30 early Q3 filers) while offering a one-click switch to
    the latest full 30/30 quarter.
  - Preserve compact holding delta recovery (`action`, `changeShares`,
    `previousShares`, `previousWeight`) in `opportunityOwnership` and row-level
    conviction/net-flow metrics (`sumWeight`, `maxWeight`, `conviction5Count`,
    `conviction10Count`, `netAdds`, `netTrims`, `quarterCounts`,
    `reportedGuruIds`) in `buildGuruHoldingsMatrix`
    (`server/investmentOpportunities.js`).
  - Keep the three primary institutional leaderboards (`集中仓位排行 / Concentrated Rankings`,
    `加仓排行（净加） / Net Buying` with `netAdds > 0`, and `净减仓排行 / Net Selling`
    with `netTrims > 0`) alongside the `Guru Matrix` comparison tab and lazy-loaded
    `Style & performance` study panel.
- **Single-Guru Research Dossier (`GuruResearchDossier` & `enrichGuruDetail`):**
  - Keep single-Guru profile drill-down (`Discover -> Guru -> <Manager>`) rendered
    through `GuruResearchDossier` (`lib/investment_guru_dossier.dart`, wired from
    `guruDetailPage()` in `lib/investment_discovery.dart`) and enriched by
    `enrichGuruDetail` (`server/investmentGuruProfile.js`, wired into
    `guruDetail()` in `server/investmentSource.js`).
  - Preserve quantitative style DNA (`concentrationTier`, `turnoverTier`,
    `avgQuarterlyTurnover`, `latestTop5Weight`), auto-synthesized `Systematic Dossier Insights`,
    cutoff-bounded `1Y / 3Y / 5Y / 10Y` 13F copy-simulation equity curves vs SPY
    with cumulative stock contributors and quarterly alpha attribution, categorized
    quarterly `New & Increased` / `Reduced & Exited` operations, 12-quarter 13F
    book trajectory & sector mix, and dated ThesisForge valuation overlay
    (`fairValue`, `marketPrice`, `modelGap` strictly `<= asOf`), while honoring
    `source_error` and `previous_source_error` fail-closed contracts.
- **Company Research Cockpit Redesign (`Research` Module — `lib/investment_research.dart`):**
  - Keep `InvestmentSource.company()` (`server/investmentSource.js`) enriched with
    strictly point-in-time `companyMeta` (`sector`, `modelRoute`, `marketCapM`,
    `cycleOperatingMargin`, `cycleFcfMargin`, `targetPE`) and `qualityAnnual`
    (`roic`, `operatingMargin`, `fcfMargin`, `cashConversion` from
    `investment_quality_annual` where `available_at <= asOf` and
    `report_period <= asOf`), without mutating the signed `snapshot` hash.
  - Keep the persistent Executive Company Hero (`research-executive-hero`),
    4-card Core Operating & ROIC KPI strip (`research-overview-kpis`),
    Fact OS fundamental diagnosis synthesis, non-repetitive Valuation Architecture
    cards, Guru & Management Guidance pulse, interactive 3-statement chart/table,
    focused `Announcements & financials` filter bar (`researchFinancialsFocus`,
    consolidated filing table without repeated body warnings or raw JSON dumps),
    unified Guru + 13F `Institutional holdings` KPIs, 3-mode `Valuation workspace`
    (`Published model` / `My DCF` / `Reverse DCF`), and full-width 2-column
    `Research records` thesis composer.
- **Fact OS Sharadar Sync & Rolling AWS Retention (`fact_os/` & `scripts/fact-os-aws-sync.py`):**
  - Keep `npm run fact-os:sync` (`bash bin/fact-os bulk-sync --profile aws-data-daily`),
    `npm run fact-os:aws-sync` (`.venv-fact-os/bin/python scripts/fact-os-aws-sync.py sync --activate`),
    `npm run refresh:all-corners` (`bash scripts/refresh-all-corners.sh`),
    `post_install_maintenance` in `scripts/fact-os-api-install.py`, and
    `--auto-retain --keep-releases 2` in `scripts/prune-public-api-candidate.py`
    committed onto `trunk` and deployed to Elastic Beanstalk so superseded
    `/var/app/data/fact-os/releases/*` generations beyond `active + rollback` are
    automatically S3-verified and evicted rather than exhausting the 60 GiB root
    volume (`insufficient_install_capacity`).

## All-Corners Earnings, Market & 13F Refresh Contract (2026-11-18)

Whenever the user asks to **update earnings / financial reports (`更新财报`), sync Sharadar, refresh market data, or update 13F/strategies**, you MUST treat it as a **complete All-Corners Refresh** rather than updating only one storage layer. Leaving any downstream module on an older date cut while claiming a completed refresh is a contract violation.

### 1. Production Three-Plane Storage Map (Know Where Every Corner Reads)

Production serves modules across three distinct storage layers that must be kept aligned:

1. **Plane 1 — Fact OS Active Release (`/var/app/data/fact-os/active.json`, local `data/fact_os`)**:
   - **14 Sharadar Canonical Tables**: `tickers`, `stocks`, `funds`, `fundamentals` (`SF1` ARQ/ARY/ART), `daily`, `actions`, `events`, `insiders` (`SF2`), `metrics`, `sp500`, `holdings` / `holdings_ticker` / `holdings_investor` (`SF3/A/B`), `descriptions`.
   - **6 Derived Groups (`DATA_DAILY_GROUPS`)**:
     - `canonical`: Parquet warehouse read by `Fundamentals` screener, `/api/investment/research/:ticker/fundamentals`, `/api/investment/research/:ticker/insiders`, and live `RAW_CLOSE` overlays.
     - `public_observations` (`observations.sqlite`): `investment_current_quotes` (latest prices across `Home`, `Discover`, `Research`, `Guru Dossier`, `Portfolio`) and `investment_quality_annual` (annual `ROIC`, `operatingMargin`, `fcfMargin`, `cashConversion`).
     - `research_inputs`: company fundamentals, corporate actions, and event inputs for `Research`.
     - `institutional_13f` (`13f-insights.sqlite`): `Discover -> 13F Insights` active-manager consensus, sector inflows/outflows, and same-manager rotations.
     - `ai_insights`: `Discover -> AI Insights` quarterly YoY/QoQ revenue acceleration and top `+pp` sector contributors.
     - `strategy_inputs` (`rulePortfolios`): `Strategies -> Four-Factor Quality Top 10` & `Ackman Top 20` (`investor-styles`).
2. **Plane 2 — Tactical Strategy Snapshots & Runtime SQLite (`server/config/*-dashboard.json` + `SQLITE_DB_PATH`)**:
   - `server/config/qqq-schd-rotation-dashboard.json` (`QQQ ⇄ SCHD Rotation`) and `server/config/hot-breakout-pullback-dashboard.json` (`Hot Breakout Pullback`): Because `t3.small` (`< 3.5 GiB` RAM) intentionally blocks in-process Python rebuilds, **every Fact OS / earnings sync MUST also run `scripts/build-qqq-schd-rotation-artifact.py --forward-extend` and `scripts/build-breakout-pullback-artifact.py` locally**, commit the updated JSONs to `trunk`, and deploy the backend package so tactical strategies never freeze behind `Fact OS`.
   - `SQLITE_DB_PATH` (`/var/app/data/thesisforge.sqlite`, local `server/data/guru-analysis.sqlite`): Read by `/api/health`, `/api/admin/system-health`, `/api/gurus/:id/backtest`, and base `/api/valuation` snapshots. Background refreshers (`startGuruBacktestRefresher`) and startup pre-warming (`server/investmentRoutes.js`) MUST resolve Fact OS via `withActiveDataRelease` / `releaseRoot` fallback (`server/dataReleaseContext.js`) rather than empty `AsyncLocalStorage`.
3. **Plane 3 — Bootstrapped Investment Source Trio (`INVESTMENT_SOURCE_DB_PATH` `research.sqlite` + `strategy.sqlite` + `composition.sqlite`)**:
   - Supplies modeled PIT fair-value snapshots (`valuation_pit_model_runs`, `valuation_pit_financials`, `valuation_pit_guidance`), curated 30-Guru SEC 13F books & copy-simulation curves (`guru_snapshots`, `guru_exposure_snapshots`, `guru_backtests`), and `Strategy Lab` inputs. When new quarterly PIT valuation runs or new SEC 13F manager filings are accepted, rebuild and publish the verified `research.sqlite` release (`npm run build:production-research` / `scripts/install-investment-release.mjs`) so `Discover`, `Guru Leaderboards`, `Guru Research Dossier`, and `Research` fair values advance together.

### 2. Mandatory End-to-End Refresh Sequence (`npm run refresh:all-corners`)

Run `npm run refresh:all-corners` (`bash scripts/refresh-all-corners.sh`) and complete the applicable quarterly gates below:

1. **Sync All 14 Sharadar Tables & Rebuild All 6 Fact OS Derived Groups**:
   - Execute `bash bin/fact-os bulk-sync --profile aws-data-daily` (`npm run fact-os:sync`). Confirm `14/14` tables pass natural-key uniqueness and zero invalid prices, and all 6 groups (`canonical`, `public_observations`, `research_inputs`, `institutional_13f`, `ai_insights`, `strategy_inputs`) succeed.
2. **Refresh Tactical Strategy Artifacts (`QQQ ⇄ SCHD` & `Hot Breakout Pullback`)**:
   - Execute `.venv-fact-os/bin/python scripts/build-qqq-schd-rotation-artifact.py --forward-extend --fact-root data/fact_os --output server/config/qqq-schd-rotation-dashboard.json` and `.venv-fact-os/bin/python scripts/build-breakout-pullback-artifact.py --fact-root data/fact_os --output server/config/hot-breakout-pullback-dashboard.json`. Verify `dataThrough` matches the latest market session in Fact OS `stocks`/`funds`.
3. **Earnings-Season Company PIT Refresh (When Updating Quarterly Financials / Guidance / Valuations)**:
   - Ingest official SEC/UK guidance (`scripts/import-sec-official-guidance.py`, `scripts/import-official-uk-pit.py`) and earnings-call Q&A transcripts (`scripts/sync-pit-earnings-transcripts.py`, `npm run enrich:valuation-transcript-qa`).
   - Recompute deterministic PIT company valuation snapshots (`scripts/refresh-pit-from-sharadar-api.py` / `scripts/build-pit-valuation-source.py`), pass `npm run audit:pit-release` (`verifyPitValuationRelease.js`) and `npm run audit:valuation`, build migration artifacts (`npm run build:pit-migration`), and verify `npm run build:research -- --check`.
4. **45-Day SEC 13F Window Refresh (When New Institutional Filings Arrive)**:
   - Update CUSIP & security master (`scripts/build-guru-sec-cusip-manifest.mjs`, `scripts/build-guru-security-master.py`), run the atomic 13F + 5Y/10Y curve matrix procedure (`npm run refresh:13f`), and rebuild/install the updated `research.sqlite` release (`npm run build:production-research`).
5. **Publish & Atomically Activate on AWS S3 + Elastic Beanstalk**:
   - Run `npm run fact-os:aws-sync` (`scripts/fact-os-aws-sync.py sync --activate` with proxy env vars unset if no local proxy is running) and confirm `aws.activeRelease.releaseId == aws.dataReady.releaseId` with `publicationStatus: "verified"` and EC2 root disk `< 75%` used (`active + rollback` retention).
   - Commit updated `server/config/*-dashboard.json` (and any code/doc updates) onto `trunk`, push to `origin/trunk`, and deploy the backend bundle (`npm run package:aws` -> AWS Elastic Beanstalk) so live strategies and API caches serve the new date cut immediately.
6. **Corner-by-Corner Live Verification Checklist**:
   - Before reporting completion, verify live data freshness across **every active surface**:
     - `Home` & `Discover` (`opportunities` + `13F Insights` + `AI Insights` + `Fundamentals`)
     - `Discover -> Guru` (3 leaderboards + `GuruResearchDossier` valuation overlay & curve)
     - `Research` (`priceComparison.priceDate`, latest `SF1` `ARQ`/`ARY` filing period, `qualityAnnual.roic`, `Valuation workspace`)
     - `Portfolio` (latest mark comparison date, passive income ledger, encrypted `user-portfolios` `0700` `webapp:webapp` intact)
     - `Strategies` (`investor-styles`, `qqq-schd-rotation`, and `breakout-pullback` `dataThrough` all matching latest market close)

### 3. GitHub Visual Showcase & `README.md` Screenshot Synchronization Contract

Whenever UI modules are redesigned OR a major quarterly earnings / 13F data refresh materially updates visible dashboards, keep GitHub (`origin/trunk`) visually current so `https://github.com/yudonglu1136/thesisforge` always reflects the real live product:

- **Canonical Showcase Screenshots (`docs/images/`)**:
  - `docs/images/research-cockpit-overview.png` — `Research` Executive Company Hero, 4-card ROIC/Operating KPI strip, Fundamental Diagnosis & Valuation Architecture
  - `docs/images/research-valuation-workspace.png` — `Research -> Valuation workspace` (`Published model` / `My DCF` / `Reverse DCF`)
  - `docs/images/guru-leaderboards.png` — `Discover -> Guru` 3-Leaderboards (`Concentrated Conviction`, `Net Buying`, `Net Selling`) & Matrix
  - `docs/images/guru-research-dossier.png` — Single-Guru Institutional Research Dossier & 13F Copy-Simulation Curve vs SPY
  - `docs/images/ai-insights-inflections.png` — `Discover -> AI Insights` Sector Growth Acceleration & Top Contributors Matrix
  - `docs/images/strategies-tactical-portfolios.png` — `Strategies` Full-Cycle Equity Curve, Underwater Drawdown & Tactical KPIs
- **Strict Zero-PII Capture Isolation**:
  - Always capture showcase screenshots against an **isolated local showcase build** (`FLUTTER_BUILD_OUTPUT` under `tmp/`, removed immediately after capture) backed by an **isolated temporary `USER_DATA_ROOT` / `INVESTMENT_DB_PATH` under `tmp/`** (never port `9222`, and **NEVER** connected to real private `server/data/user-portfolios` or real IBKR dollar balances!).
  - Capture at `1440x900` desktop viewport only after all loading skeletons disappear and charts/logos finish rendering. Verify every PNG visually before committing.
- **Synchronize `README.md` + `AGENTS.md` + `origin/trunk`**:
  - Keep `README.md` module descriptions, architecture diagrams, CLI commands, and inline `docs/images/*.png` references synchronized with the current production product, commit onto `trunk`, and `git push origin trunk`.

### 4. Security, Backup & Runtime Pinning Guardrails (2026-11-18)

- Keep `requireAdmin` enforced on `POST /api/valuation/:ticker/import` (`server/index.js`) so non-admin users can never trigger server-side valuation importer subprocesses.
- Keep `kinds.portfolio` in `server/userDataBackup.js` synchronized with every table created in `server/userPortfolioStore.js` (including `portfolio_analysis_snapshots`, `portfolio_passive_ledgers`, `portfolio_account_sync_status`, `user_preferences`, and `readonly_brokers`) so encrypted user-data backups (`npm run user-data -- backup`) never fail on schema checks.
- Keep `withActiveDataRelease` (`server/dataReleaseContext.js`) wrapping startup pre-warming (`server/investmentRoutes.js`) and `releaseRoot()` falling back to `readDataRelease()` outside HTTP middleware so cold requests never hit unpinned `14s+` discovery rebuilds and background jobs always resolve `/var/app/data/fact-os/active.json`.

### 5. Full-Product UX, Friendliness & Performance Milestones (2026-11-18)

- **Shell, Search & Point-in-Time (`lib/main.dart`, `lib/investment_graphite.dart`, `lib/investment_workflow.dart`)**: Global `Cmd+K` / `Ctrl+K` command search (`global-search-trigger`), smart `● Live` vs `Point-in-time replay` date badge with `showDatePicker` + 1-click `Live` reset, `?view=valuation` routed into `InvestmentWorkspace`, stable `_workspaceKey` across `Admin` switches, `401` `session-expired-banner`, and `workspace-preferences-button`.
- **`Home` & `Discover` (`lib/investment_portfolio_home.dart`, `lib/investment_guru_dossier.dart`, `lib/investment_13f_insights.dart`)**: 3-path Quickstart Launchpad for unconnected users, surfaced `homeReviewAlert` & `home-research-briefing`, working `Follow / Following` & section jump anchors on all `GuruResearchDossier` pages, clickable `Active Funds` tickers, virtualized `13F Insights` stock list (`maxHeight: 680`), and interactive hover tooltip on `Fundamentals` trend charts.
- **`Research` (`server/researchWorkbench.js`, `server/investmentOpportunities.js`, `lib/investment_research.dart`)**: Event-sourced editable/archivable research records (`parentRecordId`, `status`, `tags`, calendar review picker, Markdown copy), cross-company `researchNotebook`, universal Fact OS `Watch / Unwatch` (`active: false`), and unsaved note draft guard.
- **`Portfolio` (`server/investmentPortfolio.js`, `server/portfolioIncome.js`, `server/portfolioRisk.js`, `lib/investment_portfolio*.dart`)**: Restored `Valuation & stress` tab (`portfolio-tab-stress`) with Fact OS `TOTAL_RETURN_ADJUSTED_CLOSE` risk series, after-tax `totalConfirmedNet` & `pendingShortPuts` collateral/premium, `Cost & P&L` column, parsed OCC option badges clickable to underlying Research, single-account & asset-kind filters, and per-account IBKR token rotation / removal (`DELETE /api/portfolio/accounts/:accountId`).
- **`Strategies` (`lib/investment_rule_portfolios.dart`, `lib/investment_breakout_pullback.dart`, `lib/investment_qqq_schd_rotation.dart`, `lib/investment_strategy_lab.dart`)**: Above-the-fold live model target strips + jump anchors across all 4 strategies, dynamic historical cutoff multiples, research-compliant rotation wording, lazy-mounted 3rd top-level tab `Options Hedge Lab` (`HedgeLabPanel`), and expandable/archivable saved custom strategies (`POST /api/investment/strategy-rules/archive`).
- **Health & `60fps` Performance (`server/databaseTableSummaries.js`, `server/publicHealthWorker.js`, `server/translationClient.js`, `lib/investment_research.dart`)**: `O(1)` Fact OS `catalog.json` `stocks` freshness summary in `publicHealthWorker`, 512-entry LRU cache + per-actor rate limiting on `POST /api/translate/zh`, frozen memoized tactical strategy slices for `O(1)` `jsonTransport` `WeakMap` ETag hits, `ValueListenableBuilder` typing isolation, bounded `cacheWidth` avatar decoding, and exact `CustomPainter.shouldRepaint` predicates.

### 6. IBKR Self-Service Multi-Account Flow, Per-User Language Habit Persistence & Payload Slimming (2026-11-18)

- **User-Side IBKR Self-Service & Per-Account Verification (`server/userPortfolioStore.js`, `server/portfolioClient.js`, `lib/main.dart`, `lib/investment_portfolio_tools.dart`)**:
  - `portfolio_account_sync_status` tracks per-account verification state (`verified` / `failed` / `pending`) and exact IBKR error codes (`1003`, `1012`, `1013`, `1014`, `1015`, `1018`, `1019`) without mutating `connectionRevision`.
  - `addPortfolioAccount` deduplicates in-place by `id`, `replaceAccountId`, or matching `ibkrFlexQueryId` on token rotation, and supports `replaceFailedAccounts: true` so stale broken accounts never poison a newly verified IBKR/Yodlee account.
  - `IbkrPortalGuideBanner` explains why IBKR uses read-only `Third-Party Services -> Yodlee` Flex tokens instead of retail browser OAuth popups, clarifies that `Third-Party Data Feeds: There are no active third-party data feeds` is normal, and opens IBKR Portal in a new tab.
- **Cross-Session & Cross-Device Per-User Language Persistence (`server/userPortfolioStore.js`, `server/index.js`, `lib/browser_location_web.dart`, `web/index.html`, `lib/main.dart`, `lib/investment_graphite.dart`)**:
  - Language habit (`'zh'` vs `'en'`) persists across `localStorage['thesisforge.language.v1']`, 1-year `tf_lang` cookie (`.thesisforge.tech`), OAuth `redirectTo`, and authenticated `GET/POST /api/user/preferences` (`user_preferences` table), with 1-click `中文 / EN` toggles in both desktop and mobile headers.
- **Data Consistency & Warm-Latency Slimming (`server/qqqSchdRotationStrategy.js`, `server/investorStyleDashboard.js`, `server/fundamentalResearch.js`, `server/publicAnalysisArtifact.js`, `server/investmentSource.js`)**:
  - `hydrateLiveRadarDiagnostics` keeps `QQQ ⇄ SCHD` radar text and `nextTriggers` aligned with live/cutoff gauges; `?summaryOnly=1` (`investor-styles`) and `?includeCurve=0` (`qqq-schd-rotation/analysis`) eliminate multi-MB unused payloads; `WeakMap` universe/ledger caches and per-entry `marketFactsVersion` keys keep warm API responses sub-2ms.

### 7. Multi-Account Historical NAV Continuity & Anti-Overwrite Contract (2026-11-19)

- **Durable Multi-Day IBKR NAV Persistence (`server/portfolioClient.js`, `server/userPortfolioStore.js`)**:
  - Every positive daily `EquitySummaryByReportDateInBase.total` row returned by IBKR Flex statements MUST be batch-upserted into `portfolio_nav_points` (`writeUserPortfolioNavPoints`, `source = 'ibkr_equity_summary_in_base'`), never just the single current report date. Audited `ibkr_equity_summary_in_base` observations must never be overwritten by approximate `holdingsTotalValue` sums on the same date, and older rolling dates (`> 365d`) must never be deleted on refresh.
- **Resilience to IBKR `Error 1018` / `1019` History Rate Limits & `connectionRevision` Updates**:
  - Fetch multi-account IBKR Flex queries sequentially (`150ms` stagger in `loadFreshPortfolioDashboard`) rather than firing concurrent `Promise.allSettled` bursts.
  - When a secondary `{periodDays: 365}` history query fails or a new sub-account / rotated token updates `connectionRevision`, `retainSavedHistoricalEvidence` and `readUserHistoricalAccountBackup` MUST retain both `historyEvidence` AND full historical `navHistory` + `inceptionDate` per broker `accountId` across all verified `portfolio_report_snapshots`.
  - `POST /api/investment/portfolio-analysis/sync` (`forceRefresh = true` in `server/investmentPortfolio.js`) must always recompute when `!saved.exact` rather than serving a stale cached analysis snapshot.
- **Verified Pre-Inception `$0` Sub-Account Continuity (`server/portfolioReport.js`, `server/portfolioHome.js`, `server/portfolioHistory.js`)**:
  - Adding a newly opened or newly funded sub-account (`inferAccountInceptionDate`) must never chop off or cliff older accounts' pre-inception NAV, realized P&L, or cash-adjusted P&L history (`Account 1 + $0` strictly prior to verified `inceptionDate`), while still failing closed on missing interior dates or unverified partial windows.

### 8. Full iOS / iPhone Standalone WebApp & Native Release Adaptation (2026-11-19)

- **Full-Screen iOS Standalone WebApp Shell (`web/index.html`, `web/brand/ios-splash/*.png`, `web/brand/thesisforge-apple-touch-icon-180.png`, `vercel.json`, `scripts/ios-webapp-shell.test.mjs`)**:
  - `web/index.html` must declare `viewport-fit=cover`, `apple-mobile-web-app-capable="yes"`, `apple-mobile-web-app-status-bar-style="black-translucent"`, `format-detection="telephone=no"`, `height: 100dvh`, `overscroll-behavior: none`, `180x180` + `192x192` black `TF` touch icons, and all 5 iPhone portrait `apple-touch-startup-image` splash PNGs (`750x1334`, `1170x2532`, `1179x2556`, `1290x2796`, `1320x2868`).
- **Apple HIG Native Mobile Terminal, v3 Fullscreen WebClip & Zero-Redirect OTP (`lib/investment_graphite.dart`, `lib/main.dart`, `lib/investment_portfolio_home.dart`, `lib/investment_portfolio.dart`, `lib/investment_discovery.dart`, `web/download/ThesisForge_iPhone_App.mobileconfig`, `test/ios_responsive_adaptation_test.dart`)**:
  - `.mobileconfig` `v3` (`web/download/ThesisForge_iPhone_App.mobileconfig`) MUST preserve exact case-sensitive `<string>com.apple.webClip.managed</string>`, `<key>FullScreen</key><true/>`, `<key>IgnoreManifestScope</key><true/>`, and `<string>https://thesisforge.tech/?launch=ios_webclip</string>` (matching Supabase's canonical Site URL), while `LoginScreen` offers top-featured **Zero-Redirect Email 6-Digit OTP (`signInWithOtp` + `verifyOTP`)** so iPhone users never trigger an external `SFSafariViewController` browser bar.
  - Mobile viewports (`< 1100px`) render a calm `46px` single-row top header (`TF` + compact `● Live` pill + circular `mobile-search-trigger` & `mobile-account-sheet-button` opening native `mobile-account-bottom-sheet` with language, PIT date, Admin, Install Guide, and Sign out) and a strict **5-tab Apple-HIG bottom bar** (`home`, `discover`, `research`, `book`, `strategies`), keeping desktop `graphiteRail()` (`>= 1100px`) 100% untouched.
  - Narrow mobile Home (`< 600px` `LayoutBuilder`) renders a frameless Portfolio Hero, an above-the-fold 264-day thumb-scrubbable NAV curve (`compactMobile: true`), a compact `2x2` Bento grid (`mobile-portfolio-bento-grid`), and Apple-Stocks density holdings rows.
- **Snowball Analytics iOS v4 Velvety Visuals & 100% Interactive Native Bottom Sheets (`lib/investment_graphite.dart`, `lib/investment_portfolio.dart`, `lib/investment_portfolio_home.dart`, `lib/investment_portfolio_passive_income.dart`, `lib/investment_discovery.dart`, `lib/investment_research.dart`, `test/ios_responsive_adaptation_test.dart`)**:
  - Mobile (`< 640px` / `< 600px`) uses Snowball Analytics' velvety layered surfaces (`#0D0F14` midnight slate canvas + `#161B24` `20px`-radius cards with `Colors.white.withValues(alpha: 0.05)` hairlines), keeping desktop (`>= 1100px`) 100% untouched.
  - Hero features a top portfolio switcher pill (`mobile-hero-accounts-pill`), split-decimal typography (`$494,970` bold `#F8FAFC` + `.70` muted `#64748B`), dual `999px` tinted return pills (`mobile-hero-realized-pill`, `mobile-hero-session-pill`), a glowing gradient curve with dashed gridlines & `InkWell` metric/range tracks, `2x2` circular-icon summary cards (`mobile-bento-realized`, `mobile-bento-session`, `mobile-bento-cash`, `mobile-bento-positions`), a dedicated cash-income banner (`mobile-bento-income-banner`), a Donut Ring `资产分布` card (`allocation-open-all-sheet`), and `股票/ETF` ⇄ `期权` holding rows with `38px` squircle logos and `4px` weight bars.
  - Every mobile card, pill, banner, and holding row opens a rich dark iOS bottom sheet (`mobile-realized-pnl-sheet` with 3 tabs `标的归因` / `按日流水` / `股息与权利金` + 1-tap `sheet-switch-chart-realized`; `mobile-daily-pnl-sheet` with `sheet-switch-chart-estimate`; `mobile-cash-accounts-sheet` with per-account `accountMeta` breakdown; `mobile-positions-sheet`; and `mobile-position-detail-sheet` with `position-sheet-open-underlying`).
- **Snowball Pocket Edition iOS v5 — 4-Tab Mobile Pruning & 100% In-App Native Login (`server/authHandoffRoutes.js`, `server/index.js`, `web/index.html`, `lib/main.dart`, `lib/investment_graphite.dart`, `lib/investment_home.dart`, `lib/investment_portfolio_home.dart`, `test/ios_responsive_adaptation_test.dart`)**:
  - **100% In-App Native Login (Zero Safari Browser Redirect)**:
    - `server/authHandoffRoutes.js` provides AES-256-GCM encrypted single-use session handoff (`POST /api/auth/handoff/start`, `POST /api/auth/handoff/complete`, `POST /api/auth/handoff/poll`) and 6-digit device pairing codes (`POST /api/auth/pair-code/create`, `POST /api/auth/pair-code/redeem`).
    - `web/index.html` intercepts `?auth_handoff=` at `0ms` before Flutter boots, clears `location.hash`, completes the server handoff, and displays a Snowball 6-digit pairing card (`#tf-pair-code-box`) while the standalone iPhone `TF` WebClip polls `/api/auth/handoff/poll` (`1600ms` + `AppLifecycleState.resumed`) to call `setSession(refreshToken)` inside the App automatically.
    - `LoginScreen` offers a 2-mode segmented toggle (`login-mode-code` 6-Digit Code / Auto-Sync vs `login-mode-password` Email + Password with `AutofillHints` for iPhone FaceID instant sign-in), hides browser-redirecting Google OAuth on `< 640px` mobile and standalone WebClip, and exposes 1-tap `设置 / 修改 App 直登密码` (`showSetAppPasswordDialog`) + `生成其他设备 6 位数字秒登码` (`showDevicePairCodeDialog`).
  - **Strict 4-Tab Snowball Mobile Feature Pruning (`screenWidth < 640`, Desktop `>= 1100px` 100% Untouched)**:
    - Prunes mobile bottom navigation strictly to 4 personal-portfolio tabs (`总览 / Overview`, `持仓 / Holdings`, `收益 / Income`, `账户 / Account`), removing desktop-heavy `Discover`, `Research`, `Strategies`, and `mobile-search-trigger` from `< 640px` mobile navigation while keeping all 6 desktop rail modules (`>= 1100px`) 100% untouched.
    - Tapping any stock or option in `总览` or `持仓` opens a mobile-native valuation & position snapshot sheet (`mobile-stock-snapshot-sheet`) rather than routing to the multi-column desktop `Research` screen.

### 9. Flagship `Discover -> Copycat Playbook / 大师作业` 13F Execution Dashboard & Continuous Daily MTM Guru NAV (2026-11-21 / 2026-11-22)

- **Navigation Placement & Backward Compatibility (`lib/investment_discovery.dart`, `lib/investment_workflow.dart`, `lib/investment_explorer.dart`, `lib/investment_home.dart`)**:
  - Replaces the legacy `Fundamentals / 基本面` tab immediately after `Discover -> Guru / 大师持仓` (`'managers'`) with **`Copycat Playbook / 大师作业` (`'copycat'`)** (`13F Insights` -> `Guru` -> `Copycat Playbook` -> `AI Insights`).
  - Legacy `?discoverTab=fundamentals` links cleanly redirect to `'copycat'` (`replaceBrowserQuery({'discoverTab': 'copycat'})`), while standalone `FundamentalsPanel` and `/api/investment/fundamentals*` remain preserved for backward-compatible unit tests and direct API callers.
  - Deep-link state persists via `cc_scheme`, `cc_weightMode`, `cc_blotter`, and `cc_quarter`. Legacy `?cc_scheme=hf4_smart_flow` / `?scheme=hf4_smart_flow` URLs cleanly fall back to the default flagship `qqq80_exqqq_monopoly`.
- **Reproducible Fact OS Precompute, PIT SEC N-PORT QQQ Exclusion & Live Daily Extension (`scripts/build-guru-copycat-playbook-artifact.py`, `server/config/rule-universe-qqq.json`, `server/config/investor-strategy-taxonomy.json`, `server/config/guru-copycat-playbook-dashboard.json`, `server/guruCopycatPlaybook.js`, `server/investmentRoutes.js`)**:
  - `npm run build:copycat-playbook` (`scripts/build-guru-copycat-playbook-artifact.py`) computes 51 strict statutory `T+45` rebalancing quarters (`2014 Q1` – `2026 Q3`, `10 bps` round-trip execution friction, daily mark-to-market NAV through latest close) purely from `FactRepository("data/fact_os")`, `server/config/rule-universe-qqq.json` (official SEC N-PORT QQQ snapshots `2019 Q4–2026 Q3` + PIT Top-100 Non-Financial NASDAQ `2014 Q1–2019 Q3` with `GOOG/GOOGL`, `CMCSA/CMCSK`, `FOX/FOXA/TFCF` dual-class safeguards), and `server/config/investor-strategy-taxonomy.json`.
  - `GET /api/investment/guru-copycat-playbook` (`loadGuruCopycatPlaybookDashboardLive`) and `GET /api/investment/guru-copycat-playbook/snapshot` enforce strict `asOf` point-in-time cutoffs (`filedAt <= asOf`, masking future `exitDate > asOf` realized returns) AND dynamically extend `dailyCurve` + headline KPIs forward on every new trading close from Fact OS `TOTAL_RETURN_ADJUSTED_CLOSE`, `price_points`, and `investment_current_quotes`.
- **Continuous Daily Guru NAV Across ALL Guru Surfaces (`server/marketData.js`, `server/investmentGuruProfile.js`, `server/investmentGuruStudy.js`, `server/index.js`, `fact_os/pipeline/aws_worker.py`)**:
  - When `LIVE_MARKET_TAIL_ENABLED=true` on production API instances, `loadPriceSeries` and `loadPriceSeriesBatch` (`server/marketData.js`) chain verified Yahoo Finance `v8/finance/chart` total-return `adjclose` tail sessions strictly after Fact OS's last published date onto Fact OS's last `TOTAL_RETURN_ADJUSTED_CLOSE` anchor (matching `scripts/build-guru-copycat-playbook-artifact.py`'s `px_dedup` tail extension), keeping both `Copycat Playbook` and all 57 `Discover -> Guru` 5Y/10Y curves continuous through the latest US trading close even when upstream Sharadar lags.
  - `server/investmentGuruProfile.js` and `server/investmentGuruStudy.js` bridge `localDatabase.js` (`readGuruBacktest` / `readGuruBacktestProxy` / `readGuruBacktestVersion`) when `source.canonicalMarket === true`, selecting whichever valid audited curve (`source.db` vs `guru-analysis.sqlite`) carries the fresher `window.end` / terminal equity date.
  - `POST /api/internal/data-release` (`server/index.js`) triggers background `refreshScheduledGuruBacktestWindows` wrapped in `withActiveDataRelease` whenever a new Fact OS `releaseId` is verified on AWS Elastic Beanstalk, keeping all 57 manager 5Y & 10Y curves synchronized with the latest trading close.
  - `fact_os/pipeline/aws_worker.py` (`sync_source`) automatically falls back from `HTTP 401/403` `bulk_sync` to incremental query `sync` so scheduled AWS StepFunctions daily Fact OS runs never stall on provider bulk-archive tier limits.
- **5 Low/Moderate-Turnover Schemes (`hf4_smart_flow` Retired) & 5 Bloomberg-Grade Modules (`lib/investment_copycat_playbook.dart`, `GuruCopycatPlaybookPanel`)**:
  1. **Flagship #1 Default `qqq80_exqqq_monopoly` (`80% QQQ + 20% Ex-QQQ Monopoly Compounders`) & 5-Scheme Switcher**: Default flagship `qqq80_exqqq_monopoly` with 1-click toggle between **`Top-5 Conviction-Weighted`** (`~18.7% CAGR`, `+0.3% vs QQQ`, `+5.3% vs SPY`, `22.8%` annual turnover; `2026 Q3` live book: `80% QQQ` + `V, GE, MCO, UNH, SPGI`) and **`Top-8 Equal-Weight (2.5% × 8)`** (`~19.0% CAGR`, `+0.6% vs QQQ`, `<20%` annual turnover, `>60%` rolling 3Y beat-QQQ win rate; `+ TSM, PGR, TDG`), alongside `barbell_70_30`, `monopoly_compounders` (`Conviction` ⇄ `Equal-Weight`), `pre2014_legends`, and `new_adds_catalyst`. The `380%` high-turnover `hf4_smart_flow` scheme is retired by explicit user request while preserving `q1HfDumpRadar` negative risk-avoidance alerts.
  2. **12-Year Interactive `$100k` Daily MTM Equity Curve & Underwater Drawdown Scrubber**: `CustomPainter` vs `SPY` & `QQQ` continuous through the latest trading close (`NAV Through YYYY-MM-DD (Daily MTM)` badge), with `Log / Linear` toggle, calendar-year excess strip (`2014–2026`), position-count sensitivity (`Top-5`..`Top-35`), and 3 empirical copycat traps.
  3. **Current Quarter (`2026 Q3`) Actionable Blotter**: 4 sub-tabs (`Active Scheme Blotter` with `All / New & Big Adds / Cheaper Than Guru` filters, `16-Stock Master Blueprint`, `Q3 Exits & >50% Slashes`, and `Q1 HF Dump Minefield Radar` surfacing `RDDT`, `RVMD`, `NBIS` conflict alerts) with 1-click ticker jump to `Research`.
  4. **16 Tracked Gurus Panorama Matrix**: Style bucket filters (`L1_COMPOUND`, `L2_CATALYST`, `L3_DEEPVAL`), 5 sort dimensions (`Copyability Grade`, `T+45 Alpha`, `T+45 Retention %`, `T+45 CAGR`, `Top-10 Concentration`), continuous daily MTM `final100k` / `navEndDate`, inline Top-12 holdings & cost-basis drawer, and 1-click jump to `GuruResearchDossier`.
  5. **51-Quarter Historical Rebalance Snapshot Explorer (`2014 Q1` – `2026 Q3`)**: Clickable `WIN / MISS / LIVE` quarterly heatmap tiles, `Prev / Next` + dropdown selector, `Entered (+k)` / `Exited (-m)` / `Core Held` diff chips, and per-stock realized `T+45` return & `bps` attribution table.

### 10. `Discover -> CTA Flow Radar / CTA 资金流雷达` Systematic Flow Surface & OOS Regime Signals (2026-11-22)

- **Navigation & Deep-Link Contract (`lib/main.dart`, `lib/investment_discovery.dart`, `lib/investment_workflow.dart`, `lib/investment_explorer.dart`, `lib/investment_cta_flow_radar.dart`)**:
  - Adds an independent `Discover` tab **`CTA Flow Radar / CTA 资金流雷达` (`'cta_radar'`)** (`13F Insights` -> `Guru` -> `Copycat Playbook` -> `CTA Flow Radar` -> `AI Insights`).
  - Both `/?view=discover&discoverTab=cta_radar` and shorthand `/?discoverTab=cta_radar` route directly into `Discover -> CTA Flow Radar` (`TerminalHome` infers `'discover'` when `discoverTab` is present without an explicit `view`), persisting `cta_asset` (`SPY` / `QQQ`) and `cta_horizon` (`5D` / `10D`).
- **Zero-Lookahead Rob Carver 6-Speed EWMAC Artifact & Dynamic Live Tail (`scripts/build-cta-flow-radar-artifact.py`, `server/config/cta-13f-scale-pit.json`, `server/config/cta-flow-radar-dashboard.json`, `server/ctaFlowRadar.js`, `server/investmentRoutes.js`)**:
  - `npm run build:cta-flow-radar` (`scripts/build-cta-flow-radar-artifact.py`) computes 12-year out-of-sample (`2014-01-02`..latest close, `2005` warmup) continuous volatility-targeted Rob Carver 6-speed EWMAC (`2/8, 4/16, 8/32, 16/64, 32/128, 64/256`, `FDM = 1.26`, `70%` 36D EWMA vol + `30%` 2520D long vol, `10%` no-trade buffer, 3-day smoothing), binary 5-window SMA benchmark (`10/20/50/100/200`), and `RV20/RV60` Vol-Control flows, calibrated strictly point-in-time (`T+45` statutory filing lag) across 31 SEC Form 13F trend-following & macro institutions (`$112.39B` in `2014-Q1` -> `$673.42B` in `2026-Q3`, `5.18x` growth; 5D flow surface endpoint `R² = 0.7621` `SPY`, `0.7833` `QQQ`).
  - `GET /api/investment/cta-flow-radar` (`loadCtaFlowRadarDashboardLive`) serves sub-millisecond cached snapshots, supports zero-lookahead historical `asOf` stepping from the `2024-12-31` state checkpoint (including dynamic zero-lookahead recomputation of `signalBacktest` / `signal_backtest` from `evalSeriesPre2025` + stepped daily bars), and dynamically chains live daily `SPY`, `QQQ`, `^VIX`, and `^VIX3M` closes when `LIVE_MARKET_TAIL_ENABLED=true`.
- **5 Institutional Terminal Visual Sections (`CtaFlowRadarPanel`)**:
  1. **Hero Control Strip, 5 KPIs & 2 Real-Time Regime Signal Beacons**: 1-click `SPY` ⇄ `QQQ` and `5D (1W)` ⇄ `10D (2W)` toggles, Spot Close & 25D deleveraging, Carver `F` & 12Y percentile, `VIX/VIX3M` Term Lock, `+3%/-3%` Marginal Convexity Ratio, `$0B` Net-Flow Breakeven Flip Price, plus (a) **Carver Marginal Short Exhaustion Buy Signal** (`F <= -10` & `+3%/-3%` convexity `>= 1.80x`, `p = 0.0041` on `SPY +63D` with `10/10` `100%` win rate) and (b) **VIX Backwardation Cliff Breach Guardrail** (`VIX/VIX3M >= 1.00`, `p = 0.0021` 5D RVol surge).
  2. **Module A — Dual-Track Price-Shock Flow Sensitivity Curve & Exact Level Matrix**: Interactive `CustomPainter` separating **Pure Price Marginal Impulse vs `0%` Flat** (solid Mint/Coral) from **Combined Net Systematic Flow** (dashed Sky Blue) with an Amber diamond at `$0B` Net-Flow Breakeven, paired with the `-5% .. $0B Flip .. +5%` matrix table.
  3. **Zero-Lookahead Signal Backtest & Dip-Entry Limit Simulator (`signalBacktest`, `2014–2026`, `>=20D` Cooldown)**: 3 selectable signal regimes (`exhaustion_convexity`, `quadrant2_combo`, `vix_backwardation_lock`), `10D / 20D / 60D` post-signal max further drawdown & days-to-trough summary, `+10D / +20D / +60D / +120D` total-return win rates & medians/means vs unconditional all-day baseline (`p`-values), interactive 5-mode **20D Dip-Entry Limit-Order Simulator** (`0%` Signal Close, `-2%`, `-3%`, `-5%`, and **`3-Tranche DCA: 0% / -2% / -5%`** quantifying fill rate, residual 20D MAE, and missed V-rally `+60D` opportunity cost), horizontal median trajectory bar chart (`_CtaSignalHorizonBarPainter`), and reverse-chronological **Episode-by-Episode Trigger Ledger** marking `2026-11-20` as `LIVE` (`excluded` from completed denominators).
  4. **Module B — 12-Year OOS Empirical Scorecard & 6-Episode Battleground Timeline**: Myth-buster warning against unconditional breakdown shorting (`p = 0.67`, `43.5%`–`51.3%` 21D V-whipsaw), VIX backwardation filter (`p = 0.0021`), Carver vs SMA exhaustion alpha (`p = 0.0041`), and interactive regime cards (`2018-Q4`, `2020-03`, honest **`2022` Slow-Bear Caveat**, `2024-08`, `2025-04`, and `2026-11` Live).
  5. **Collapsible Methodology & 31-Institution SEC Form 13F PIT Scale Drawer**: 54-quarter PIT scale bar chart, live 6-speed EWMAC sub-forecast & 1D flip table, and 5-window SMA benchmark table.

### 11. `Discover -> Crisis Observatory / 危机观测` 6-Light & AD Divergence Pure-Options Observatory (2026-11-23)

- **Navigation & Deep-Link Contract (`lib/main.dart`, `lib/investment_discovery.dart`, `lib/investment_workflow.dart`, `lib/investment_explorer.dart`, `lib/investment_graphite.dart`, `lib/investment_crisis_observatory.dart`)**:
  - Adds an independent `Discover` tab **`Crisis Observatory / 危机观测` (`'crisis_observatory'`)** (`13F Insights` -> `Guru` -> `Copycat Playbook` -> `CTA Flow Radar` -> `Crisis Observatory` -> `AI Insights`), reachable directly via `/?discoverTab=crisis_observatory` and `/?view=discover&discoverTab=crisis_observatory`, persisting `co_strategy` and `co_window`.
- **Zero-Lookahead 6-Lights + AD Divergence + Dual-Track TP Pure-Options Engine (`scripts/build-crisis-observatory-artifact.py`, `server/config/crisis-observatory-seed-inputs.json.gz`, `server/config/crisis-observatory-dashboard.json`, `server/crisisObservatory.js`, `server/investmentRoutes.js`, `server/index.js`)**:
  - `npm run build:crisis-observatory` (`scripts/build-crisis-observatory-artifact.py`) reproduces the audited `2015-01-02 -> 2026-11-20` (`$200,000` DRIP start, T+1 Open execution, `+/-2.5%` per-leg option slippage, continuous-dividend BSM + empirical OPRA cubic skew, **100% QQQ equity core forever — ZERO T-Bill/bond timing**, and **Dual-Track Take-Profit**: Track 1 Acute Panic `VIX/VIX3M >= 1.10` OR Track 2 Late-Life Slow-Bear Deep-ITM Lock `DTE <= 45 & Put Bid >= 5.0x Entry Put Ask`) pure-options lineup: default flagship **`U1_PureOptions`** (`$1,604,274.43`, `+$315,969.65` net alpha vs pure QQQ `$1,288,304.78`, `19.15%` CAGR, `-31.52%` Max Drawdown beating pure QQQ `-35.12%` by `3.60pp`, `0.844` Sharpe, `+519.30` extra QQQ shares), `B1c_PureAD` (`$1,508,125.75`), `D2_SixLights` (`$1,479,351.46`), and `H2_G4_PriceGate` (`$1,380,701.67`), with exact 4-factor convexity attribution (`Delta + Gamma + Vega + Theta/Slip == Net PnL`) on every option tranche.
  - Served at both `GET /api/investment/crisis-observatory` and `GET /api/discover/crisis-observatory` (`loadCrisisObservatoryDashboardLive`), enforcing auth + `portfolioResponsePrivacy`, mapping any legacy `?strategy=U4_DualEngine` cleanly to `U1_PureOptions`, supporting zero-lookahead historical `asOf` slicing (masking `exit_date > asOf` open tranches), and chaining live `QQQ`/`^VIX`/`^VIX3M`/`^VXN` bars when `LIVE_MARKET_TAIL_ENABLED=true`.
- **4 Minimalist Visual Blocks (`CrisisObservatoryPanel`, Apple Finance / Linear Calm Architecture)**:
  1. **Clean Verdict Header (`今日信号结论`)**: Single calm status dot + plain-human bilingual headline (zero raw engineering IDs) + live `QQQ` quote & `VIX/VIX3M` readout + 1-sentence human summary + minimalist 3-column horizontal status strip separated by `1px` vertical hairlines (`Core Equity: 100% QQQ Held` | `First-Half Naked Put (50%)` | `Second-Half Collar (50%)` paused below `-5%` drawdown, zero T-Bill bond timing) + collapsed-by-default `"查看触发条件 / View Trigger Rules"` disclosure detailing both Track-1 (`VIX/VIX3M >= 1.10`) and Track-2 (`DTE <= 45 & Put >= 5x`) harvest rules.
  2. **Minimalist Six Macro Crisis Signals Strip (`六大危机信号状态`)**: Unified calm card with flat `3x2` desktop (`2x3` tablet, `1-col` mobile) `1px` hairline grid (`●` lit / `○` off, plain signal title, right-aligned primary number, 1-line muted subtitle — zero heavy red-bordered boxes) + single 1-line `US Stock Advance-Decline Line (AD Line)` footer bar.
  3. **Hero Interactive Equity Curve & Crisis Zoom-In (`_CrisisObservatoryChartPainter`)**: Plain-human strategy switcher (`Naked Put + Collar` / `Breadth Divergence` / `Six-Lights Collar`) + `Log / Linear` toggle on left, 3-number hero comparison strip (`Ending Value`, `Net Alpha`, `Max Drawdown`) on right, single horizontal zoom chip row (`All 12Y · 1Y · 3Y` + 7 historical crisis windows `2015-08 .. 2026-08_11_LIVE`), spacious 2-curve Apple-Stocks style chart (solid Emerald strategy with subtle gradient fill vs muted dashed `Buy & Hold QQQ`, `▲` hedge open & `◆` Dual-Track TP harvest diamonds distinguishing Track-2 `put5x_dte45_tp` with an amber stroke ring), clean floating hover card (`crisis-chart-hover-tooltip`) showing strike & Track-1/Track-2 harvest tags, and collapsed-by-default crisis lights & `VIX/VIX3M` sub-track toggle.
  4. **Zoomed-In Crisis Story & Clean Action Timeline (`危机复盘与具体操作`)**: Episode narrative + 3 clean horizontal metrics (`Drawdown vs QQQ`, `Option Profit Harvested`, `QQQ Shares Added`) + clean chronological option tranche rows labeling Track-1 (`1.10 Panic Harvest`) and Track-2 (`5x Slow-Bear Harvest`) with tap-to-expand 4-factor convexity breakdown (`Delta / Gamma / Vega / Time & Slippage`) and 12-year scope toggle.

