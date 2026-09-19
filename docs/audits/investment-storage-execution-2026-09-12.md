# Storage audit execution addendum — 2026-09-12

This addendum records completed AWS storage work reported by the deployment operator. It supersedes the pending-cleanup/install status in `investment-storage-2026-09-12.md`; it does not certify the complete application or Guru-curve release.

## Executed and verified

- SQLite-managed checkpoint reduced the active research WAL from **2,368,653,952 bytes to 0**. The main database inode and schema were preserved. The WAL was not manually deleted.
- Removed only `/var/app/data/guru-valuation-audit-20260905/runtime.sqlite`, an inactive **2,739,396,608-byte** audit copy, after verifying that its gzip decompresses to the exact same size and SHA-256. The **303,698,427-byte** `runtime.sqlite.gz` remains recoverable in place; the encrypted EBS rollback snapshot is retained. The proof and hashes are recorded in the preceding audit. No directory-wide deletion was performed.
- Installed the three isolated public databases under `/var/app/data/investment-releases/redesign-20260912-v1/`. Each matches the audited SHA-256 below, is root-owned with mode `0444`, and resides in the `0555` release directory. No partial downloads or install locks remained. The private investment journal retains mode `0600`.
- Final measured disk availability: **14,553,849,856 bytes free of 32,132,542,464 bytes**, exceeding the installer's 10 GiB reserve. No new compute infrastructure was added.

| Installed file | SHA-256 |
| --- | --- |
| `research.sqlite` | `1eb637ca72dab198075b92f1a72b6536fff0e5c4da18be1578bc2c8e922bfce9` |
| `strategy.sqlite` | `54767025ada6ab58648b72ce282c2b632d84a2bd69eaa05c4fc219c1a07e42a5` |
| `composition.sqlite` | `d95bfc4ef45b6c5acdfa793014644f05b70b2523a59007c4d180924db8c77c9b` |

Full SQLite integrity, foreign-key, schema and SHA checks were performed on these exact local producer files; AWS verified transferred byte identity and bounded schema/isolation checks. This is not a claim that the large full integrity scans were repeated on the live EBS volume.

## Duplicate prevention now in place

The installer uses exclusive locks, exact content contracts, resumable no-clobber transfer and a projected-free-space guard. Repeating an identical finalized release reuses it without downloading another copy. The same complete content under a different release ID is rejected with an explicit existing-release reference. Relevant installer/read-only-smoke tests passed **15/15**.

The research source, normalized strategy warehouse and consistent-vintage composition price store intentionally overlap in observations and provenance. This is separate from accidental repeat downloads. Their provider, adjustment-basis and lineage contracts remain intact; no price table was dropped to create apparent savings. Existing primary/immutable keys prevent repeat append records at their defined grain.

## Still planned, not completed

Future refreshes need a safe incremental/versioned-data and bounded-retention workflow. Another complete release may not fit while preserving the 10 GiB reserve; the installer must stop before download rather than delete active data automatically. Inactive release removal still requires exact consumer checks and verified recovery material. Existing compressed backups and S3 backup objects were not comprehensively deduplicated or automatically expired. User portfolios, private stores and unrelated databases remain outside this cleanup scope.
