# Launch preparation — local verification

2026-09-12. **Not a release approval or production performance claim.**

## Changes in this preparation batch

- API proxy: production HTTPS gate, canonical API-only routing, private namespace denial, bounded body/deadlines, sanitized failures. Streaming, gzip and conditional 304 remain covered.
- Portfolio cache: bounded entries/active loads; coalesced refreshes; connection invalidation prevents late cache writes; overload is retryable. SQLite user handles use bounded LRU; durable data is not an in-memory cache.
- Dependency fix: qs 6.15.2 → 6.16.0, required side-channel 1.1.0 → 1.1.1. `npm audit --omit=dev` reported zero known vulnerabilities at verification time.
- 42 avatars losslessly re-encoded, 144×144 unchanged. Byte total 1,157,636 → 1,001,130 (13.52% saved), now under the unchanged 1 MiB budget. Every RGBA pixel and ancillary metadata chunk was compared before replacement. [Per-file evidence](avatars-lossless.json).
- Immutable avatar URL version: `144-20260912r2`. PNG originals retained under `/tmp/tf-guru-png-backup-20260912-launch` until explicitly cleaned.
- AWS packaging refuses dirty/untracked/non-trunk source before touching the archive. Independent Flutter build output is opt-in and must not exist; default deployment output behavior remains unchanged.

## Checks actually run

| Check | Result |
|---|---|
| Node 22.23.2 `node --test server/*.test.js` | 1,486 passed, 0 failed |
| Node 26 server baseline after initial changes | 1,484 passed; the final two portfolio HTTP tests subsequently passed on Node22 |
| `npm run test:launch-prep` | 25 passed, 0 failed |
| `npm run test:performance` | 47 passed, including avatar budget previously failing |
| `flutter test --reporter expanded` | 527 passed; existing off-screen tap warnings remain |
| `flutter analyze` | No issues |
| `npm run audit:i18n` | Passed |
| `npm run test:ontology` | Python 3 tests + Node 22 tests passed |
| `AUTH_DEV_BYPASS=false FLUTTER_BUILD_OUTPUT=<new path> npm run build` | Successful isolated release build |
| Scoped `git diff --check` | Passed |
| Source gate on actual working tree | Correctly **blocked** (uncommitted/untracked work); no package/deploy |

Build: `/tmp/tf-launch-build.ssOOWI/site`. Node22 log: `/tmp/tf-launch-node22-final.K4PB8T`. Flutter log: `/tmp/tf-launch-flutter-final.NutCB4`. Build log: `/tmp/tf-launch-build-log.ePKdX4`.

The first Flutter run caught two stale expected avatar URL versions; both assertions were updated to the new immutable URL, then the entire 527-test suite was rerun successfully. No numerical or coverage budget was relaxed.

## Reproduce

```sh
npm run test:launch-prep
npm run test:server
npm run test:performance
npm run test:ontology
npm run audit:i18n
flutter analyze
flutter test --reporter expanded
```

For Node/AWS parity use Node22.23.2. Lossless image tooling was isolated in a temporary venv (`zopfli==0.4.3`, `Pillow==12.3.0`) and is not an application dependency. `scripts/optimize-guru-pngs.py` is check-only by default; applying requires a new backup directory and fails on pixel/metadata differences.

## Still required

These tests are functional/budget checks, not the mandatory before/after API benchmark. No claim is made of ≥30% API p95 improvement, ≤5% regression, capacity or production latency. Three comparable 60-sequential/60-concurrent(c20) runs, full semantic hashes/compression/304 gates, live browser QA and restore/migration rehearsals remain outstanding. The bundled Ontology snapshot is empty and the serving strategy population is 28 versus 32 configured, so a current complete release dataset is not yet available. Production SQL/restore access and financial-provider entitlement remain blockers.

Security guidance drove fail-closed transport and tenant-cache isolation. PostgreSQL/Supabase guidance shaped the separate migration plan; no PostgreSQL user store or cloud resource has been provisioned or claimed verified in this batch.
