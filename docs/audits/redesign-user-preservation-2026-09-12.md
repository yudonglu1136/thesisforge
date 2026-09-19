# Redesigned release: private user-data preservation

## Result

**PASS — all 16 original private databases are byte-for-byte unchanged after deployment.** The only additional database is the expected, empty investment journal. This is a user-data preservation conclusion, not a sign-off on public market-data freshness, the Guru readiness matrix, or all live application workflows.

## Compared snapshots

- Before maintenance/deployment: verified restored backup captured **2026-09-12 20:10:14.939 UTC**, 16 databases.
- After deployment: verified restored backup captured **2026-09-12 20:50:15.162 UTC**, 17 databases.
- Sources: `thesisforge-private-before-storage-maintenance-20260912` and `thesisforge-private-after-redesign-verified-20260912`, supplied by the operator's encrypted backup-and-restore workflow. Each backup is consistent per database, not a cross-database global transaction.
- Comparison code: operator-local `tf-compare-restored-user-backups.mjs`, using Node 22.22.3 and read-only SQLite connections. The comparison reads already-restored local snapshots only; it does not access AWS, recovery keys, or decrypt credential/report envelopes.

## Original stores

| Check | Before | After | Result |
| --- | ---: | ---: | --- |
| Original databases | 16 | 16 retained | 16/16 identical file SHA-256 and schema |
| Per-user portfolio databases | 14 | 14 | All files identical |
| Registered user mappings | 14 | 14 | No removal, remapping, or duplicate subject |
| Encrypted connections | 2 | 2 | Same owning database, primary key and ciphertext |
| Encrypted broker reports | 2 | 2 | Same owning database, primary key and ciphertext |
| Historical NAV records | 29 | 29 | All row fields unchanged |
| Login activity records | 6 | 6 | All row fields unchanged |
| User registry records | 14 | 14 | All row fields unchanged |
| Recovery connection records | 0 | 0 | Unchanged |

No original database, table or row was removed. No row was added or modified within the original 16 databases between these two snapshots. All original databases passed SQLite integrity and foreign-key checks. Primary-key-based comparisons bind each record to the same store; comparison output contains no account identifiers, email addresses, positions, monetary amounts, credentials or decrypted reports.

The earlier 18:23 backup was also compared with the 20:10 baseline: all 14 portfolio files were identical. The only differences then were forward-only `last_seen_at` updates in two login rows and two registry rows, with no account or financial-record changes.

## Expected new investment journal

The seventeenth database, `investment.sqlite`, is a legitimate additive store:

- **0 investment events**; no pre-existing local-preview data was copied into it.
- Only `investment_events` and SQLite's internal `sqlite_sequence` tables are present.
- Its 10 application columns match the released journal structure.
- Unique event IDs and unique owner/operation pairs are enforced; the owner/kind/sequence index exists.
- Immutable UPDATE and DELETE triggers are present.
- SQLite integrity check passed; foreign-key errors: **0**.
- Its file hash remained unchanged after read-only inspection.

## Limits

Exact encrypted-byte preservation proves that the stored envelopes were not changed or reassigned; it does not independently prove live credential validity. The operator's separate backup workflow verified remote and off-host restore plus the existing credential/report envelopes. This comparison did not repeat decryption or expose keys. New live writes after the post-deployment snapshot are outside this comparison window.
