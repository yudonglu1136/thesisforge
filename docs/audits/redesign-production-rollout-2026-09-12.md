# Redesigned ThesisForge production rollout — 2026-09-12

## Deployed, with explicitly unresolved readiness checks

The redesigned application is deployed. This is not an all-features/data-readiness certification. The public health audit still returns 503, and the current Guru comparison cache cannot pass the current identity checks.

Published source: `47973e1d7d834d1b9d7be175552271696a72c8d4` on `trunk`, following the redesigned release `35ccdf7d712d1c6f67d19c9112176a6ae97038ea`. Both were built from the clean release clone; the original development worktree was preserved.

- AWS version: `guru-redesign-20260912-47973e1`, Ready/Green at the infrastructure layer.
- Vercel deployment: `dpl_4PiMHzqwYv45Mker4Z3Dv2HM8dvj`.
- Production domains: `https://thesisforge.tech` and `https://www.thesisforge.tech`.
- Both domains returned the exact compiled JavaScript SHA-256 `817cc6b776adef75d3ada775a9df1fdfab671b6b14be08a485425b64d511e8f3`, the enabled workflow marker, and matching public build metadata. Revalidation headers remain enabled.
- The old-interface root cause included `www` being only a manual deployment alias. It is now registered as a production project domain, without introducing redirects or changing existing login origins.

## Data and privacy boundaries

The three audited public stores are isolated under the immutable `redesign-20260912-v1` release. The legacy AWS database and all existing user databases retain their paths. Only the eight reviewed investment/TLS activation settings were added; hashes of all original environment values were preserved. Authentication bypass remains disabled. No local preview owner identity or local user portfolio was copied into production.

See [storage execution](investment-storage-execution-2026-09-12.md) and [user preservation](redesign-user-preservation-2026-09-12.md). The post-deployment backup restored all 17 stores remotely and off-host. All 16 original stores were byte-identical to the verified pre-maintenance backup; the sole new journal was empty. The configured journal is now included exactly once when it shares the portfolio directory.

Actual final disk reading after the compatibility follow-up: **14,552,981,504 bytes available**. Roughly 5.1 GB of redundant/unreclaimed local storage was released while retaining verified recovery material. The follow-up deployed code only, not another copy of the public databases. No compute instance, database service or hosting-plan upgrade was introduced.

## Verification

- Main redesigned candidate: 1,251 server tests and 564 Flutter tests passed; Flutter analysis and translation checks passed.
- Focused final backup/proxy/nginx regression suites: 32/32 passed on Node 22.22.3. An initial sandbox run could not bind local test ports; the authorized rerun passed all tests.
- Both live origins: anonymous portfolio, investment and admin requests returned 401 with `no-store`; public internal-maintenance requests returned 404 with `no-store`.
- Eight concurrent health probes shared the bounded health work; eight simultaneous unauthenticated portfolio requests completed in roughly 0.48–0.98 seconds. This measures isolation, not authenticated throughput or health readiness.
- AWS TLS and application services remained active. The application listens on loopback behind nginx/TLS.

Three read-only strategy cases ran sequentially with production worker limits on the actual existing AWS instance:

| Case | Runtime | Peak process RSS | Result |
| --- | ---: | ---: | --- |
| QQQ, annual KMLM, 1.5x leverage | 0.954 s | 171 MB | Pass |
| Four-factor, 30% valuation exclusion | 61.749 s | 503 MB | Pass |
| Ackman/Hohn/Kantesaria, 61% exclusion, annual KMLM | 9.268 s | 228 MB | Pass |

Each completed through 2026-09-11 with 21 snapshots and zero snapshot cash. This is a bounded three-case production-capacity smoke, not exhaustive configuration certification or an authenticated end-to-end browser test.

The effective nginx response timeout is now 120 seconds, verified using the live configuration. Vercel's generated function configuration explicitly contains `maxDuration:120`; its existing Hobby Fluid setup supports this without an upgrade. Backend mixed-strategy workers remain capped at 90 seconds and the Flutter request at 95 seconds. Near the worker limit, network/serialization overhead still matters.

## Remaining work — do not describe as passed

1. `/api/health` still reports `health_audit_timeout` at its bounded eight-second worker deadline. Whole-table/JSON aggregate scans are suspected from source review; per-stage production timing is needed before optimizing. Ordinary API isolation is not proof that this audit passed.
2. Separate identity checks on the isolated research store establish a zero ready upper bound for both 32-manager 5Y and 10Y comparison windows. Existing caches have incompatible security identity or are missing. They must be rebuilt and validated, not relabeled as current.
3. The four newly configured managers still lack profiles in the isolated public research source, although the strategy catalog contains 32 enabled managers. This is an outstanding source-parity task, not proof that historical backfill is complete.
4. Financial API refresh remains paused as requested. AVGO's stored financial snapshot remains 2026-Q2, available 2026-06-09; comparison quotes are current through 2026-09-11. A fresh quote does not imply a fresh financial model.
5. Live browser verification reached the real sign-in screen. No authenticated session was available, so live owner-portfolio/admin UI acceptance remains pending user sign-in. No auth token or owner identity was manufactured.
6. Future complete data generations need reviewed incremental/versioned refresh and retention. The installer now refuses duplicate complete content and insufficient projected disk space; it does not silently delete older backups or deduplicate every S3 object.

Operational basis: [nginx response timeout](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_read_timeout), [Vercel function duration](https://vercel.com/docs/functions/configuring-functions/duration#duration-limits), and [production alias behavior](https://vercel.com/docs/cli/alias).
