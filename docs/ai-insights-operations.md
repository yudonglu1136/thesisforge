# AI Insights

AI Insights is the independent Discover module replacing Value Flow. It reads a
bounded immutable projection of Local Fact OS; it does not depend on valuation
model coverage or perform provider requests during page loads.

## Data and refresh

- Registry: `server/config/ai-insights-universe.json` (59 companies: 9 capital
  investment, 28 hardware, 22 software). Alphabet is counted once through GOOGL.
- Canonical inputs: Fact OS `fundamentals` ARQ, `tickers` and relevant `actions`,
  pinned to one catalog.
- Builder: `fact_os/ai_insights.py`; retains available public-date revisions,
  signed cash-flow fields, nulls, actual report periods and source identities.
- Output: `data/fact_os/derived/ai-insights/generations/<hash>.json`; the manifest
  is published last at `data/fact_os/derived/ai-insights/manifest.json`.
- Each generation also has an immutable `generations/<hash>.manifest.json`
  containing its artifact path and SHA-256. The publisher writes this sidecar
  before advancing the latest manifest and preserves the previous generation's
  sidecar. Both latest and pinned historical API reads verify artifact bytes
  against their corresponding checksum; a missing historical sidecar expires
  that snapshot explicitly rather than loading unverified bytes.
- Receipts: `data/fact_os/audit/ai-insights-*.json`. Same-input replay is a no-op.

Build once from already synchronized local facts:

```sh
npm run build:ai-insights
# Equivalent entry point:
bash bin/fact-os ai-insights
```

`bash bin/fact-os sync` now builds AI Insights only when fundamentals, ticker
identity, or relevant corporate actions changed successfully and the dependency
set is complete. Price-only and unrelated table updates record a skipped build;
they do not change financial evidence IDs or publish a redundant generation.
The existing daily task invokes the same pipeline. A real source or
derived-publication failure records failure and leaves the previous manifest
intact. No second timer, source key, per-company HTTP loop or database copy is
required.

Keep `FACT_OS_ROOT` consistent between the builder and backend. Deployment must
package the AI Insights manifest, its referenced generation and that generation's
checksum sidecar under that root;
source histories are not browser assets. Existing generations support saved
analysis references; retain their checksum sidecars as well. Neither belongs to
routine Parquet-only GC.

Production packages are created and installed with:

```sh
node scripts/package-ai-insights-artifact.mjs \
  --source data/fact_os --output <staging-release-directory> \
  --release-id ai-insights-YYYYMMDD-vN --retain 8
node scripts/install-ai-insights-artifact.mjs \
  --source <staging-release-directory> --target <immutable-install-directory>
```

The EB postdeploy hook verifies the archive hash and byte length, then installs
the exact release under `/var/app/data/ai-insights/releases/<release-id>`.
Production startup requires both `AI_INSIGHTS_ROOT` and
`AI_INSIGHTS_RELEASE_MANIFEST_PATH`; schema, generation, source hash and every
file digest are validated before the service is ready.

## API

All routes require the existing investment authentication:

```text
GET /api/investment/ai-insights
GET /api/investment/ai-insights/rankings
GET /api/investment/ai-insights/companies/:ticker
GET /api/investment/ai-insights/compare
GET /api/investment/ai-insights/methodology
```

Analytical queries carry `asOf`, `quarter` (for example `2026Q2`), and `window`
(8, 12 or 20). Related detail/compare requests carry the returned `snapshotId`.
Changing the cutoff, quarter or window starts a fresh analysis. A manifest
update must not mix generations within an existing analysis. Missing artifacts
fail explicitly; there is no demo-data fallback.

The old `/api/investment/value-flow` returns 410/no-store. Old `discoverTab=valueflow`
links open `discoverTab=aiinsights`; language and cutoff survive. The retired
UI, service and full taxonomy were removed. A small legacy provenance registry
preserves existing decision compatibility. New decisions store verified
`ai_insights` snapshot context and source identity.

## Measurement contract

Financial quarters use the provider's `calendardate` alignment, with actual
report period and public date preserved. As-of selection filters both the
report period and `datekey`, then chooses the latest eligible ARQ revision.
This reconstructs public information at day precision; it does not claim a
complete historical vendor archive, intraday tradability, or the platform's
original historical observations.

The current registry is a fixed retrospective research basket, not a historical
investable universe. Whole-company revenue includes mixed operations, and net
cash capital investment includes non-AI uses. Neither is relabeled as pure AI
revenue or gross equipment purchases. Supply-chain revenues overlap and cannot
be added to spending to calculate an AI return on investment.

Growth uses paired current/prior companies and base-period amount weighting.
Disclosed totals and the narrower comparable growth samples are both exposed.
Unverified provider zero capex is missing for comparisons; net disposal inflows
retain their sign. Negative earnings and cash flow remain negative. Quarterly
ARQ values are not differenced a second time. TTM requires consecutive quarters.

The artifact retains relevant provider mergers, acquisitions and spin-offs with
their canonical action keys and lineage. Event visibility uses the provider's
effective date as an explicit date-level proxy, not a fabricated announcement
timestamp. Comparisons spanning a known business-scope change are excluded from
paired aggregate growth; growth/quality scores remain unavailable while their
input windows span the event without a comparable scope bridge. Reported company metrics remain
inspectable with their comparability state. SNDK's pre-spin revenue is excluded
when WDC is already in the same aggregate to avoid parent/subsidiary overlap.
These checks are conservative and do not establish organic growth or complete
corporate-action coverage. NBIS's predecessor scope review is marked as known
from the registry review on 2026-09-22; its name change is not treated as proof of
an earlier business-scope transition date.

Growth and quality scores use versioned, disclosed weights and complete eligible
peer cohorts of at least eight companies. Missing inputs do not receive zero or
automatic reweighting. Search, filters and pagination do not change benchmarks.
Hardware and software scores are relative to their respective groups. Scores
are descriptive operating comparisons, with no claimed stock-return validation.

## Verification

```sh
.venv-fact-os/bin/python -m unittest fact_os.test_ai_insights fact_os.test_sync fact_os.test_sync_plan
npm run test:ai-insights
node --test server/investmentWorkflow.test.js server/retiredProductRoutes.test.js server/caddyRetirement.test.js
flutter analyze
flutter test test/investment_ai_insights_test.dart test/investment_ai_insights_navigation_test.dart
npm run audit:i18n
npm run test:performance
npm run audit:storage-layout
```

Use a new output path for the full storage audit; its receipt is append-only:

```sh
.venv-fact-os/bin/python scripts/audit-fact-os-storage.py --root data/fact_os --output data/fact_os/audit/ai-insights-storage-<unique-run>.json
```

The implementation acceptance record is maintained separately from this
runbook. A successful local build is not a production deployment, and hook tests
are not evidence that a future unattended daily run has already completed.
