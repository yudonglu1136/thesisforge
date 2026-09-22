# Fundamentals recovery and redesign — 2026-09-22

## Problem and verified cause

The production failure is not an empty screen result. The API host was missing
both the Python Fact OS reader and a canonical data root. A read-only probe as
`webapp` reproduced `local_runtime_unavailable` in 166 ms. Production had no
`/opt/thesisforge-fact-os` runtime, no `/var/app/current/data/fact_os`, and no active
data-release pointer. Retrying the old screen could not install those resources.
SSM diagnostic: `c09193d0-dd4c-4791-89ad-8dd5bde628fb`.

## Product changes

- Search-first company browser. All fact companies are available without a
  valuation model or a mandatory research signal.
- Explicit sorting: recent comparable reports, revenue growth, operating margin,
  cash-flow margin, or signal magnitude. Missing metrics sort last, not as zero.
- Compact company-logo rows, three comparable metrics, 30-row server pagination.
- Advanced thresholds collapsed initially; existing six evidence lenses retained.
  Mobile uses one research-focus selector and a focused company detail view.
- Business / valuation / financials / 13F reuse the existing analysis and source
  components. Research remains reachable even without a valuation model.
- Evidence and method explanations, counterevidence and observation saving stay
  available. Query/filter state survives a retry. Cutoff changes invalidate old
  detail requests. Errors are not replaced with stale model-company lists.
- Single-flight full-universe loading reuses the existing generation-aware cache.
  Sanitized Fact OS failures return HTTP 503 and `private, no-store`.

The product-design review drove the search-first hierarchy and reduction of
pre-result controls; no new financial data system or scoring system was added.

## Scope-safe production data plan

Reuse the existing, checksum-validated AWS canonical artifact; do not rebuild or
activate unrelated derived groups, public backtests, valuation candidates, or
private accounts. Existing 13F / Guru / AI / Research model database paths stay
unchanged. SEC and broker sources remain independent.

- Private bucket: `thesisforge-production-378477120101-us-east-1`.
- Canonical generation:
  `def80071e34055dd536687757ad5f920e2a8083da0a830cc6dcf7b7709fe660f`.
- Scoped release:
  `5c318a56abe766f1e74e41ac2a84c7efd80d5d612649af88d99dda15b46f3e84`.
- Manifest: `fact-os/published/releases/<scoped-release>.json`.
- Size: **3,151,446,576 bytes / 348 files**, 14 ready canonical source tables.
- Target: `/var/app/data/fact-os/releases/canonical/<generation>`.
- Preflight free space: **12,932,665,344 bytes** on the API volume.
  Budget 3.2 GB payload plus runtime/staging overhead; no full database copy.
- Retain this immutable generation for at least seven days, and longer while
  active or referenced by saved research / rollback. No GC or archive deletion
  is performed in this release.
- Install the existing reader runtime hook, then use
  `scripts/fact-os-api-install.py` with the exact candidate key and
  `--expected-release none`. Existing checksum, schema, real `webapp`-UID read,
  manifest-last activation and live API ACK gates must all pass.
- No ingestion, new scheduler, worker cutover or private database migration.
  This is not acceptance of the separate AWS daily-pipeline project.

## Verification

Local actual data as of 2026-09-22: **5,418 fact companies**, 1,576 with research
signals; latest available report date 2026-09-21. UBER search/detail has eight
quarterly evidence records and 13 trend points. Its revenue growth is 12.17%,
TTM operating margin 12.13%. No current valuation model is required by the probe.

`scripts/smoke-fundamentals-readonly.mjs` verifies discovery, UBER detail/sources,
PIT cutoff, page disjointness and repeatability. Local cold read: 2,656 ms.
Three runs of 60 warm requests / concurrency 20 yielded P95 144 / 129 / 126 ms.
These are local measurements, not claims of production latency.

- Node final full server regression: 1,659 passed, 15 skipped, zero failed.
- Python Fact OS regression: 200 passed.
- Focused Fundamentals + adjacent explorer: 29 passed.
- Full Flutter: 570 passed, 32 failures. Exact failing-test names match the
  independently recorded prior sector-release baseline: 27 Discover-lens,
  two growth-quality, one opportunities, one portfolio-Guru, one valuation-memory.
  No assertions were removed to obtain a pass. New intentional heading assertions
  were updated; these unrelated baseline failures are not represented as green.
- Flutter analysis, bilingual audit and auth-enabled production build checked.
- Actual browser: EN/ZH desktop and 390×844, search, company selection,
  source modal, advanced filters, responsive detail. Widget tests also exercise
  saved observations, review, lazy 13F and valuation decomposition.
- Full Fact OS storage audit passed (`deleted_files: 0`). Layout audit retains
  11 pre-existing sibling/legacy-path findings; no databases were removed.

Browser screenshots are bounded QA files in `/private/tmp/fundamentals-*.png`,
not licensed dataset exports. Authenticated production interaction requires a
real signed-in session; health and unauthenticated 401 checks alone do not prove
that user flow. Deployment identities and actual production checks must be
reported separately after installation, not inferred from these local results.

## Release and recovery

Commit only this feature's UI, server, tests, smoke probe and documentation.
Preserve unrelated `design-qa.md`, Strategy documents/scripts and the separate
unpublished Strategy commit. Package from the exact committed, pushed `trunk`
source using the existing source-provenance guard. No SQLite seed, PIT migration,
private records, provider secrets or frontend assets belong in the AWS bundle.

Pre-release AWS version: `sector-c7b4026`. Pre-release Vercel deployment:
`dpl_D8JUKiBmRADtWPGBxCPpQNJuCc2X`.
If install/ACK fails, the installer restores the prior data pointer (none on the
first install). If application verification fails, restore the previous AWS
version and point **both** public Vercel aliases to the prior deployment.
Retain immutable data for diagnosis; do not roll back private databases or
delete raw archives. A health-green deployment is not a data-read acceptance.

### Production installation regression found during acceptance

The first installation passed file checks and the real API UID's canonical
read, but the live ACK connection was refused. The installer defaulted to the
development port 8787 when EB's user configuration omitted `PORT`; the existing
production loopback runners use EB's 8080 default. The installer correctly
removed the new active pointer. Four regression tests now cover the EB default,
explicit port, process-environment port and malformed ports. The repair changes
only port selection; it never relaxes authentication, loopback or ACK checks.
Retry reuses the already-verified immutable files instead of duplicating them.

The production read-only probe then passed on 5,419 companies (the AWS canonical
generation is newer than the local 5,418-company generation). AMZN's model value
was 235.6928225956114 and UBER's 156.2045336056933. Production cold discovery took
14.5 seconds; warm concurrency-20 P95 was 766 / 688 / 656 ms. To keep that cold
scan out of the first user's visit, the authenticated loopback release ACK now
verifies and warms the same in-process discovery function. It rejects missing,
future-dated and wrong-cutoff results; a separate CLI process is not considered
API prewarming. This does not add a scheduler or expose an unauthenticated route.
