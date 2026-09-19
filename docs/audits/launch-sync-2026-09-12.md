# AWS/local release audit — 2026-09-12

## Subsequent bounded release

After the audit below, the owner-only Admin and user-portfolio preservation code was deployed as `70b2ec2`, without replacing research or user databases. Real encrypted off-host backups and exact pre/post user-data preservation checks passed. See [the production release record](owner-portfolio-production-release-2026-09-12.md). The historical observations below describe the earlier audit; the full application release decision remains NO-GO and its unrelated data/infrastructure gaps are not marked resolved by the account-safety release.

## Decision

**NO-GO for the full application release.** The user has authorized deployment
after verification, using existing resources and no new fixed-cost infrastructure.
No additional deployment approval is being requested. The remaining blockers are
real data/configuration and release acceptance gaps, not missing authorization.

No application version, production database content, DNS or public alias was
changed in this audit. No RDS, instance, load balancer or other paid infrastructure
was created. Temporary inspection permissions were removed.

## Verified directly on AWS

- EB `guru-analysis-api-prod` still runs `guru-admin-20260906-730dc21`.
- Both public domains return HTTP 503 from `/api/health`. Its Guru module reports
  only **1/56** current displayable required curves in that older deployment.
  The current source catalog requires **64** 5Y/10Y outcomes, not 56.
- Unauthenticated portfolio requests return 401; public internal routes return 404.
- Actual server runtime is **Node v22.22.3**, `web.service` active.
- Actual research path: `/var/app/data/guru-analysis.sqlite`, 2,739,519,488 bytes.
- **16 private databases:** 14 per-portfolio files, one registration index and one
  login-activity file. These counts do not imply 14 active customers or accounts.
- All three existing private schema groups match fresh databases initialized by
  the current local code: columns, table definitions, indexes and schema hashes.
- The final operator audit ran as the application's OS identity. No foreign-owned
  private WAL/SHM sidecars were found.

Private account identifiers, emails, credentials, holdings, balances and database
rows were not exported into this report or Git. Host fingerprints were checked
against AWS console evidence before SSH authentication. The temporary port-22
rule allowed only the operator's `/32`; its exact rule ID was revoked afterwards.
The unsuccessful temporary SSM registration/channel policy was also removed.

## Database synchronization gaps

| Domain | Local | AWS evidence | Required action |
| --- | --- | --- | --- |
| Research schema | 26 tables | 24 tables; all common definitions match | Verified migration/import of `investment_quality_annual`, `investment_quality_metadata` and `investment_quality_pit` index |
| Strategy warehouse | 21 tables; 4.1 GiB local file | `STRATEGY_DATA_DB_PATH` not configured | Install an audited candidate and verify its generation, source versions and runtime adapter |
| Saved research/events | Separate local investment store exists | `INVESTMENT_DB_PATH` and workflow enablement not configured | Initialize the production private store with real authenticated identities; never copy `local-dev-user` events |
| Existing user stores | Current code's schemas verified | Matching 14 portfolio + registry + login schemas | Preserve current paths, HMAC/encryption key and owner mapping; no local-to-live overwrite |
| Prices in AWS `price_points` | Local release targets 2026-09-10 | SPY 2026-09-04; QQQ/AVGO 2026-08-31; DBMF 2026-08-14; no KMLM row in this table | Audited price append/import with rollback and readback; other ETF stores were not certified by this query |
| AVGO financials | Still 2026 Q2 | Still 2026 Q2; available 2026-06-09, period end 2026-05-03 | Restore existing paid-source access and append Q3 through the normal PIT pipeline |

The existing configured Sharadar client was rechecked with one bounded AVGO
ARQ/ART request through 2026-09-12. It still returned **403 / Exceeds free tier**.
No data or refresh-success timestamp was written. This establishes an entitlement
problem for the tested credentials, not which subscription/account action caused it.
No alternate provider was silently substituted.

Local research and strategy databases both passed full SQLite integrity and
foreign-key checks. The live research database received a lightweight schema
inventory only: an initial full scan exceeded the 120-second operator deadline.
**Live research full integrity is not certified.** Run the full check on a verified
online-backup candidate before release, rather than repeatedly scanning production.

## Real-user recovery drill

The final drill ran on the existing AWS host as the app user:

- 16 existing private databases, **581,632 bytes** in the snapshots.
- Online WAL-safe copies → AES-256-GCM encrypted files → isolated restore.
- Restored authentication tags, SHA-256 digests, schema hashes, row counts and
  full SQLite integrity checks passed for every database.
- Final measured duration: **335 ms** for local backup/restore work, excluding
  SSH setup and the host inventory. This is not an application throughput benchmark.
- The recovery target was a new private `/var/tmp` directory, never the live root.
  All drill copies and the ephemeral in-memory encryption key were discarded.
- Consistency is per database, not a cross-database transaction. A real cutover
  still requires a write-freeze/checkpoint plan.

**This is not a durable or off-host production backup.** `USER_DATA_BACKUP_KEY`
is not configured on AWS, and no recurring production backup was enabled here.
The earlier S3 round-trip used synthetic data and operator credentials; neither
exercise substitutes for an installed, retained, recoverable production backup.

## Fixes and release checks added

- `scripts/database-release-audit.mjs`: read-only inspection and comparison,
  schema drift detection, optional allowlisted public-table digests, unknown vs
  differing row counts, explicit unverified-integrity state, private output files.
  It never performs migration or interprets matching counts as matching data.
- `scripts/check-production-source.mjs`: a clean checkout must also match the
  **actual published origin/trunk**, not an unpushed commit or stale tracking ref.
  Remote failure blocks packaging; existing archives are untouched by that guard.
- Legacy migration test runs the real research initializer twice and proves
  existing price fields and stored private NAV rows survive unchanged.
- Operator tool verifies AWS host identity, cleans exact temporary access, avoids
  secret/row output and audits WAL databases under the application OS identity.

Validation: 25 database/release/backup checks passed on Node 22.23.2, including
11 pre-existing database/backup checks and 14 audit/source/host checks. Production
dependency audit returned **0 vulnerabilities**. No UI code changed in this turn;
the earlier Flutter results are not a new browser acceptance run.

Final runtime-parity run used **Node v22.22.3, exactly matching AWS**: all server
tests plus the 14 audit/source/host tests passed (**1,510**, zero failures).
The production source gate still correctly blocks the current uncommitted source
set. Final EB readback confirms the old version was not replaced.

## Remaining release order

1. Restore existing financial-provider entitlement or explicitly authorize an
   independently audited alternate source. Never change sources to hide a 403.
2. Prepare one immutable candidate: reviewed public price append, PIT financials,
   quality-factor layer, strategy warehouse and full 64-outcome Guru generation.
   Resolve the source exceptions in the existing four-Guru audit.
3. Finish the low-cost HTTPS upstream on existing infrastructure; retain the
   existing Ontology endpoint. Deploying the new fail-closed proxy first would
   intentionally reject the current HTTP origin.
4. Install durable private backup/key custody and verify off-host recovery;
   prepare a fresh rollback point and protect all real user stores.
5. Rehearse schema/data imports against a production-shaped backup and verify
   unchanged non-target tables, complete generations and full integrity.
6. Assemble tested, pushed clean trunk artifacts. The current large dirty
   workspace was not bulk-committed or packaged.
7. Verify authenticated end-to-end flows, real strategy matrix and the prescribed
   same-runtime performance baseline/candidate checks; then deploy and read back
   both domains, API generation, database versions and rollback behavior.

Memory/disk snapshot: 2,006,237,184 bytes RAM, approximately 1.39 GB free RAM,
17.90 GB available on the data filesystem and low instantaneous load. This supports
continuing the existing single-host plan; it does **not** prove peak concurrency,
tail latency or capacity for unlimited backtest workers.

## Evidence and commands

Sanitized, local-only operational receipts:

- `output/aws-host-audit-y5u1TE/inventory.json` — final app-identity host audit/drill.
- `output/launch-20260912-local-runtime.json` — full local research check.
- `output/launch-20260912-local-strategy.json` — full local strategy check.

Run from the repository using the selected Node 22 runtime:

```sh
npm run test:database-release
npm run db:audit -- inspect --db /absolute/database.sqlite --kind research --output /private/new-receipt.json
npm run db:audit -- compare --expected /private/candidate.json --actual /private/aws.json
```

`--schema-only` is available for a lightweight production inventory, but cannot
pass full-integrity verification. No private database is a public-data sync source.
