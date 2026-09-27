# Research statement history recovery — 2026-09-27

## Incident and scope

The production Research overview still showed historical valuation components,
but its financial statement history failed with `local_data_unavailable`.
Inspection of API instance `i-0eabc67533fb38fca` found neither
`/var/app/data/fact-os/active.json` nor a local canonical Fact OS installation.
The earlier model-snapshot fallback did not supply financial statement history.

This repair restores public canonical facts and Research inputs. It does not run
source sync/backfill, reconstruct financial facts, change valuation models,
recompute backtests, or access private account data.

## Recovery assets

- API code/environment at inspection: `research-fallback-ce46334`.
- Source data-ready release:
  `ecb74372780f94328d3bc0c996741847ef689f73d31a80f72dddd44476fc734c`.
- Source scheduled run: 2026-09-25 04:30 UTC.
- Scoped candidate (canonical + research_inputs only):
  `ee3a14209c96a9cec758c9472711bca34c47fb4ab46c3f810b7f1f56b7b2ff08`.
- Canonical generation:
  `3f388d2be1fb4fe2a24a719808abf97abdfabeb95a50ea63237a21079cfb75fe`.
- Research input generation:
  `bfb4f9e72f7dcd214a3987a1b87ff972d2b36ff5bb15ceaf7c251df2c2696da2`.
- Root-volume backup: `snap-09f38d4c0a1712a94`, completed.
- Encrypted backup: `snap-00e5fa3158e0ddfcf`, completed.
- Initial free space: 16,508,813,312 bytes. Full candidate estimate:
  4,090,606,602 bytes. Immutable installed public data stays under
  `/var/app/data/fact-os/releases`; no cleanup or raw archive copying occurred.

## Checks completed

- 50 Python pipeline/store/publication tests passed.
- 10 Node fundamental-research/release-context tests passed.
- 25 Flutter financial-growth/Research tests passed, including both languages,
  390px layout, statement selection, annual/quarterly charts and hover growth.
- Full local Fact OS content/storage audit passed; receipt:
  `data/fact_os/audit/research-statements-storage-20260927.json`.
- Repository storage-layout audit failed on pre-existing sibling projects and
  `server/data/valuation-pit-source.sqlite`. No files were deleted to pass it.
- Actual `webapp` read against the pinned production canonical candidate:
  PLTR: 8 quarters / 6 annual observations, 13.390 seconds including optional
  peer context. Discovery: 5,422 companies, latest disclosure 2026-09-24,
  14.746 seconds. This is a data-read check, not browser/API acceptance.

## Failed attempts retained honestly

- SSM `19e948a4-cb47-459a-b134-eb651f9d5e40`: six-group installation was
  rejected before activation. The 13F artifact's SQLite-generated `sqlite_stat1`
  table is rejected by its current strict table allowlist. No validator was
  disabled, and the 13F candidate was not activated.
- SSM `253451a6-ea4f-4da1-aed2-39e902cc1ad6`: scoped candidate passed physical
  and API-user checks but the live release endpoint returned 503. The installer
  restored the previous (absent) active pointer. The public-analysis dependency
  was subsequently diagnosed below; Research was isolated without relaxing it.
- Browser verification is awaiting an authenticated production session. The
  opened Research page currently displays the normal sign-in screen; no auth
  bypass is permitted.

## Acceptance

The global activation failure was reproduced as `rule_analysis_nav_mismatch`
for all, sp500 and nasdaq100 strategy ledgers. Their reconciliation checks remain
unchanged. A narrowly routed Research serving scope now has its own atomic
pointer and live quarterly/annual statement ACK. The global pointer and public
strategy compatibility group are not changed. A pinned EB postdeploy restore
hook is included for replacement instances; it never rewinds an active scope.

Updated checks: 58 Python pipeline/installer tests, 16 targeted Node tests,
60 transport/performance-contract tests and 25 Flutter tests passed. These
include scoped activation rollback, preservation of the global pointer,
disclosure cutoff, and routing isolation from Portfolio/Strategy/Discover.

Production recovery accepted at 2026-09-27 05:24 UTC:

- Code commit `999de007f6aed527b28efd1ffd23b43b84d67ced`, pushed to trunk.
- EB release `research-statements-999de00`, Ready / Green. Application deploy
  completed 05:20:16 UTC; pinned restore configuration completed 05:23:23 UTC.
- Source-provenance gate passed using an exact committed-tree packaging staging
  directory and a separate index. The shared dirty checkout was not reset,
  stashed or included in the release. No database was bundled.
- Package SHA-256:
  `f6c6bcf16783da484a95d25be808228bf17561668c179c8e7a25e178af296a5e`.
- `THESISFORGE_RESEARCH_RELEASE_KEY` pins the scoped candidate above. The EB
  configuration-deployment restore hook performed the real installation.
- Live scoped ACK SSM `6597f915-5974-427b-9419-c0737ddd5319` returned `verified`,
  exact release/group identities and 14/14 available, backfill-complete tables.
  AMZN: 8 quarters / 8 years; PLTR: 8 quarters / 6 years. As-of: 2026-09-27.
- Historical 2026-09-22 actual-webapp probe SSM
  `7e48d1c5-f9c3-47a5-9153-b8c6b8bb7b2b` passed both histories and cutoff checks.
  PLTR latest quarterly revenue 1,935,464,000 USD; AMZN 200,606,000,000 USD;
  both periods 2026-06-30. Cold diagnostic reads took 13.958s and 5.328s.
- Full production InvestmentSource probe SSM
  `03b52548-963a-4e28-90cb-e2113173afb0` also passed using runtime configuration,
  canonical market data, and the existing model/13F paths. PLTR returned 8
  quarters / 6 years in 15.059s; AMZN returned 8 quarters / 8 years in 13.376s.
  Both reported price date 2026-09-22 and the expected scoped release identity.
  These are cold-read timings, not a claim of subsecond page rendering.
- Official Vercel-proxied Research API returned 401 to an anonymous request
  (authentication preserved) with the exact `X-Data-Release-Id` scoped identity.
- Both apex and www resolve to frontend deployment
  `dpl_Hq4GHqMSbVcrnkvBxr36gbDse1Vm`. No frontend redesign/rebuild was needed.
- The global `active.json` remains absent, as before. No global data activation
  or daily pipeline completion is claimed.

Authenticated browser interaction remains **not verified**: the available
production browser session displayed sign-in. User login was requested without
extracting credentials or bypassing auth. Bilingual/narrow-screen interactions
passed the existing Flutter tests, not an authenticated production browser test.

The aggregate `/api/health` remains HTTP 503 due to existing Guru simulation
readiness (0/57 required curves current/displayable); its legacy price module is
stale. These are not hidden or treated as repaired by the Research-scoped ACK.
The independent Strategy NAV mismatch and 13F `sqlite_stat1` validator issue
remain open. This release repairs Research financial data serving, not those
other modules or the complete daily activation pipeline.
